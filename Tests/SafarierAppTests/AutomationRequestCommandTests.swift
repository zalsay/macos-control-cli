import Foundation
import Carbon
import Darwin
import XCTest
@testable import Safarier
@testable import SafarierCore

final class AutomationRequestCommandTests: XCTestCase {
    func testMissingAppleEventHasNoCallerProof() {
        XCTAssertNil(AutomationRequestCommand.copyCallerProof(from: nil))
    }
    @MainActor func testPendingCountNotificationsAndRemoval() {
        let id = UUID()
        var observed: [Int] = []
        ManagerAutomationHooks.pendingCommandCountDidChange = { observed.append(AutomationScriptPendingCommands.count) }
        defer { ManagerAutomationHooks.pendingCommandCountDidChange = nil }
        AutomationScriptPendingCommands.register(id)
        AutomationScriptPendingCommands.didRegister()
        XCTAssertTrue(AutomationScriptPendingCommands.contains(id))
        AutomationScriptPendingCommands.finish(id)
        AutomationScriptPendingCommands.finish(id)
        XCTAssertEqual(observed, [1, 0])
    }

    @MainActor func testCompletionGateAllowsOnlyOneCompletion() {
        let gate = AutomationRequestCompletionGate()
        var completions = 0

        XCTAssertTrue(gate.run {
            completions += 1
        })
        XCTAssertFalse(gate.run {
            completions += 1
        })
        XCTAssertFalse(gate.run {
            completions += 1
        })
        XCTAssertEqual(completions, 1)
    }

    func testCompletionGateCanResumeWithoutMainQueueScheduling() {
        let gate = AutomationRequestCompletionGate()
        let resumed = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var completions = 0
        DispatchQueue.global().async {
            let didRun = gate.run {
                lock.lock(); completions += 1; lock.unlock()
                resumed.signal()
            }
            XCTAssertTrue(didRun)
        }
        XCTAssertEqual(resumed.wait(timeout: .now() + 1), .success)
        lock.lock(); let result = completions; lock.unlock()
        XCTAssertEqual(result, 1)
    }

    func testCompletionGateWinsConcurrentLateCompletionsOnce() {
        let gate = AutomationRequestCompletionGate()
        let group = DispatchGroup()
        let lock = NSLock()
        var resumes = 0
        for _ in 0..<16 {
            group.enter()
            DispatchQueue.global().async {
                _ = AutomationRequestCommand.completeSuspendedCommand(
                    gate: gate,
                    result: Data(),
                    resume: { _ in
                        lock.lock(); resumes += 1; lock.unlock()
                    }
                )
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
        lock.lock(); let result = resumes; lock.unlock()
        XCTAssertEqual(result, 1)
    }

    func testCapacityRefusalResumesSuspendedCommandOnce() throws {
        let gate = AutomationRequestCompletionGate()
        var resumes = 0

        let completed = AutomationRequestCommand.completeSuspendedCommand(
            gate: gate,
            result: Data(#"{"status":"error"}"#.utf8),
            resume: { _ in resumes += 1 }
        )

        XCTAssertTrue(completed)
        XCTAssertEqual(resumes, 1)
        XCTAssertFalse(AutomationRequestCommand.completeSuspendedCommand(
            gate: gate,
            result: Data(#"{"status":"error"}"#.utf8),
            resume: { _ in resumes += 1 }
        ))
        XCTAssertEqual(resumes, 1)
    }

    func testAppleEventResultUsesStringJSON() throws {
        let data = Data(#"{"version":1,"status":"ok"}"#.utf8)
        XCTAssertEqual(AutomationRequestCommand.appleEventResult(from: data),
                       String(decoding: data, as: UTF8.self))
    }

    @MainActor func testNextRequestCompletesAfterTimedOutCommandAndLateWorker() async throws {
        let coordinator = AutomationScriptCoordinator()
        let uid = geteuid()
        let proof = AutomationScriptCallerProof(effectiveUID: uid, pid: 123,
            auditToken: Data(repeating: 0x42, count: MemoryLayout<audit_token_t>.size))

        func run(_ request: AutomationRequest, timeout: Double,
                 handler: @escaping AutomationScriptCoordinator.Handler) async throws -> Data {
            let pendingID = UUID()
            let gate = AutomationRequestCompletionGate()
            AutomationScriptPendingCommands.register(pendingID)
            let bytes = try AutomationCodec.encodeRequest(request)
            return try await withCheckedThrowingContinuation { continuation in
                coordinator.start(data: bytes,
                    role: .manager,
                    proof: proof, currentUID: uid, timeoutSeconds: timeout, handler: handler,
                    completion: { data in
                        guard AutomationRequestCommand.completeSuspendedCommand(
                            gate: gate,
                            result: data,
                            resume: { value in continuation.resume(returning: value) }
                        ) else { return }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                if AutomationScriptPendingCommands.finish(pendingID) {
                                    XCTAssertEqual(AutomationScriptPendingCommands.contains(pendingID), false,
                                                   "pending command removed after the reply is resumed")
                                }
                            }
                        }
                    })
            }
        }

        let first = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .capabilities)
        let firstData = try await run(first, timeout: 0.02) { request in
            try await Task.sleep(nanoseconds: 120_000_000)
            return AutomationReply(requestID: request.requestID,
                outcome: .failure(AutomationError(code: .backgroundLaunchUnverified)))
        }
        XCTAssertEqual(try AutomationCodec.decodeReply(firstData).outcome,
            .failure(AutomationError(code: .timeout)))
        XCTAssertEqual(coordinator.pendingCount, 0)

        let second = AutomationRequest(version: 1, requestID: UUID(), sessionID: nil, action: .capabilities)
        let secondData = try await run(second, timeout: 1) { request in
            AutomationReply(requestID: request.requestID,
                outcome: .failure(AutomationError(code: .backgroundLaunchUnverified)))
        }
        XCTAssertEqual(try AutomationCodec.decodeReply(secondData).requestID, second.requestID)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(coordinator.pendingCount, 0)
        XCTAssertEqual(AutomationScriptPendingCommands.count, 0)
    }

    func testSyntheticAttributesRejectWrongAuditTypeAndPreserveHighBitUID() throws {
        let uid = NSAppleEventDescriptor(int32: Int32.min)
        let pid = NSAppleEventDescriptor(int32: 123)
        let bytes = Data(repeating: 0x42, count: MemoryLayout<audit_token_t>.size)
        let audit = NSAppleEventDescriptor(descriptorType: DescType(typeAuditToken), data: bytes)
        let wrong = NSAppleEventDescriptor(descriptorType: DescType(typeData), data: bytes)
        let proof = try XCTUnwrap(AutomationRequestCommand.copyCallerProof(euidDescriptor: uid, pidDescriptor: pid, auditDescriptor: audit))
        XCTAssertEqual(proof.effectiveUID, uid_t(UInt32(bitPattern: Int32.min)))
        let normalUID = NSAppleEventDescriptor(int32: 501)
        XCTAssertNil(AutomationRequestCommand.copyCallerProof(euidDescriptor: normalUID, pidDescriptor: pid, auditDescriptor: wrong))
        let shortAudit = NSAppleEventDescriptor(descriptorType: DescType(typeAuditToken), data: Data([0]))
        XCTAssertNil(AutomationRequestCommand.copyCallerProof(euidDescriptor: normalUID, pidDescriptor: pid, auditDescriptor: shortAudit))
        XCTAssertNil(AutomationRequestCommand.copyCallerProof(euidDescriptor: normalUID, pidDescriptor: NSAppleEventDescriptor(int32: 0), auditDescriptor: audit))
    }

    @MainActor func testConstructedCommandOutsideCurrentDispatchIsUnauthorized() throws {
        let description = try XCTUnwrap(NSScriptCommandDescription(
            suiteName: "Safarier Unit Test", commandName: "Request",
            dictionary: ["AppleEventClassCode": "SfUT", "AppleEventCode": "RQST", "CommandClass": "NSScriptCommand"]))
        let command = AutomationRequestCommand(commandDescription: description)
        XCTAssertFalse(NSScriptCommand.current() === command)
        let reply = try XCTUnwrap(command.performDefaultImplementation() as? String)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "error")
        XCTAssertEqual(error["code"] as? String, "UNAUTHORIZED")
    }

    // Synthetic descriptor fixtures test decoding only, not OS provenance or authorization.
    private func word(_ value: UInt32, type: DescType) -> NSAppleEventDescriptor {
        var native = value
        let data = withUnsafeBytes(of: &native) { Data($0) }
        return NSAppleEventDescriptor(descriptorType: type, data: data)!
    }

    func testSyntheticUnsignedAndMixedSenderWords() throws {
        let audit = NSAppleEventDescriptor(descriptorType: DescType(typeAuditToken), data: Data(repeating: 0x42, count: MemoryLayout<audit_token_t>.size))!
        for (uid, pid) in [
            (word(501, type: DescType(typeUInt32)), word(123, type: DescType(typeUInt32))),
            (word(501, type: DescType(typeSInt32)), word(123, type: DescType(typeUInt32))),
            (word(501, type: DescType(typeUInt32)), word(123, type: DescType(typeSInt32)))
        ] {
            let proof = try XCTUnwrap(AutomationRequestCommand.copyCallerProof(euidDescriptor: uid, pidDescriptor: pid, auditDescriptor: audit))
            XCTAssertEqual(proof.effectiveUID, 501)
            XCTAssertEqual(proof.pid, 123)
        }
        let highUID = word(0x8000_0001, type: DescType(typeUInt32))
        let proof = try XCTUnwrap(AutomationRequestCommand.copyCallerProof(euidDescriptor: highUID, pidDescriptor: word(1, type: DescType(typeUInt32)), auditDescriptor: audit))
        XCTAssertEqual(proof.effectiveUID, uid_t(0x8000_0001))
        XCTAssertTrue(proof.isAuthorized(role: .manager, currentUID: uid_t(0x8000_0001)))
        XCTAssertFalse(proof.isAuthorized(role: .manager, currentUID: 501))
    }

    func testSyntheticSenderWordsRejectInvalidTypeLengthAndPIDRange() {
        let audit = NSAppleEventDescriptor(descriptorType: DescType(typeAuditToken), data: Data(repeating: 0x42, count: MemoryLayout<audit_token_t>.size))!
        let valid = word(1, type: DescType(typeUInt32))
        let invalid: [NSAppleEventDescriptor?] = [nil, NSAppleEventDescriptor(string: "1"),
            NSAppleEventDescriptor(descriptorType: DescType(typeData), data: Data(repeating: 1, count: 4)),
            NSAppleEventDescriptor(descriptorType: DescType(typeUInt32), data: Data(repeating: 1, count: 3)),
            NSAppleEventDescriptor(descriptorType: DescType(typeUInt32), data: Data(repeating: 1, count: 5)),
            NSAppleEventDescriptor(descriptorType: DescType(typeSInt32), data: Data(repeating: 1, count: 3)),
            NSAppleEventDescriptor(descriptorType: DescType(typeSInt32), data: Data(repeating: 1, count: 5))]
        for value in invalid {
            XCTAssertNil(AutomationRequestCommand.copyCallerProof(euidDescriptor: value, pidDescriptor: valid, auditDescriptor: audit))
            XCTAssertNil(AutomationRequestCommand.copyCallerProof(euidDescriptor: valid, pidDescriptor: value, auditDescriptor: audit))
        }
        for pid in [word(0, type: DescType(typeUInt32)), word(0, type: DescType(typeSInt32)),
                    word(0xffff_ffff, type: DescType(typeSInt32)), word(0x8000_0000, type: DescType(typeUInt32)),
                    word(0xffff_ffff, type: DescType(typeUInt32))] {
            XCTAssertNil(AutomationRequestCommand.copyCallerProof(euidDescriptor: valid, pidDescriptor: pid, auditDescriptor: audit))
        }
        XCTAssertNotNil(AutomationRequestCommand.copyCallerProof(euidDescriptor: valid, pidDescriptor: word(0x7fff_ffff, type: DescType(typeUInt32)), auditDescriptor: audit))
        for badAudit in [nil, NSAppleEventDescriptor(descriptorType: DescType(typeData), data: Data(repeating: 0, count: MemoryLayout<audit_token_t>.size)),
                         NSAppleEventDescriptor(descriptorType: DescType(typeAuditToken), data: Data(repeating: 0, count: MemoryLayout<audit_token_t>.size - 1)),
                         NSAppleEventDescriptor(descriptorType: DescType(typeAuditToken), data: Data(repeating: 0, count: MemoryLayout<audit_token_t>.size + 1))] {
            XCTAssertNil(AutomationRequestCommand.copyCallerProof(euidDescriptor: valid, pidDescriptor: valid, auditDescriptor: badAudit))
        }
    }

}
