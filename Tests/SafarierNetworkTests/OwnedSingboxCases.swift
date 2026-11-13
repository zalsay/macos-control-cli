import Foundation
import Darwin
import SafarierCore
@testable import SafarierNetwork

public enum OwnedSingboxCases {
    struct Failure: Error { let label: String }
    static func waitSignal(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult { semaphore.wait(timeout: .now() + 5) }
    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock(); private var exit: ProcessExit?
        func set(_ value: ProcessExit?) { lock.lock(); exit = value; lock.unlock() }
        func get() -> ProcessExit? { lock.lock(); defer { lock.unlock() }; return exit }
    }
    public static func run(helper: URL, root: URL) async throws -> Int {
        var count = 0
        func check(_ value: Bool, _ label: String) throws { count += 1; if !value { throw Failure(label: label) } }
        func node(_ password: String) -> SubscriptionNode { SubscriptionNode(name: "test", type: .trojan, server: "localhost", serverPort: 443, password: password) }
        let manager = SingboxProcessManager(executableURL: helper, stateDirectory: root.appendingPathComponent("state"))
        let id = UUID()
        let identity = try await manager.startOwned(profileID: id, node: node("secret-value"))
        try check(identity.profileID == id && identity.proxy.host == "127.0.0.1", "identity")
        try check(!identity.description.contains("secret-value"), "redacted")
        try check(!FileManager.default.fileExists(atPath: manager.stateDirectory.path), "no state directory")
        do { _ = try await manager.startOwned(profileID: id, node: node("secret-value")); throw Failure(label: "duplicate") } catch is SingboxProcessError { count += 1 }
        do { _ = try manager.start(profileID: id, node: node("secret-value")); throw Failure(label: "crossmode") } catch is SingboxProcessError { count += 1 }
        let foreign = SingboxProcessManager.OwnedIdentity(profileID: identity.profileID, ownershipID: UUID(), pid: identity.pid, proxy: identity.proxy)
        do { try manager.requestStopOwned(foreign); throw Failure(label: "foreign synchronous stop") } catch SingboxProcessError.notRunning { count += 1 }
        do { _ = try await manager.stopOwned(foreign); throw Failure(label: "foreign identity") } catch SingboxProcessError.notRunning { count += 1 }
        try check(manager.pendingOwnedCount == 1, "foreign identity leaves owner")
        do { try manager.stop(profileID: id); throw Failure(label: "legacy stop owned") } catch SingboxProcessError.notRunning { count += 1 }
        try check(try manager.port(for: id) == identity.proxy.port, "legacy stop retains owned port")
        let exit = try await manager.stopOwned(identity)
        try check(exit != nil, "observed stop")
        try check(manager.pendingOwnedCount == 0, "released")
        do { _ = try await manager.startOwned(profileID: UUID(), node: node("early")); throw Failure(label: "early") } catch SingboxProcessError.exitedEarly { count += 1 }
        let legacyID = UUID()
        _ = try manager.start(profileID: legacyID, node: node("legacy"))
        _ = try manager.waitUntilReady(profileID: legacyID)
        do { _ = try await manager.startOwned(profileID: legacyID, node: node("secret")); throw Failure(label: "legacy crossmode") } catch SingboxProcessError.alreadyRunning { count += 1 }
        try manager.stop(profileID: legacyID)
        try FileManager.default.removeItem(at: manager.stateDirectory)
        let deinitID = UUID(), legacyDirectory = root.appendingPathComponent("legacy-deinit")
        var deinitManager: SingboxProcessManager? = SingboxProcessManager(executableURL: helper, stateDirectory: legacyDirectory)
        _ = try deinitManager!.start(profileID: deinitID, node: node("legacy"))
        let deinitPort = try deinitManager!.waitUntilReady(profileID: deinitID)
        let deinitConfig = deinitManager!.configurationFileURL(for: deinitID), deinitPID = deinitManager!.pidFileURL(for: deinitID)
        deinitManager = nil
        try check(!FileManager.default.fileExists(atPath: deinitConfig.path) && !FileManager.default.fileExists(atPath: deinitPID.path), "legacy deinit cleans state")
        try check(SingboxProcessManager.isPortAvailable(deinitPort), "legacy deinit terminates child")
        try FileManager.default.removeItem(at: legacyDirectory)
        let sentinelID = UUID()
        try FileManager.default.createDirectory(at: manager.stateDirectory, withIntermediateDirectories: true)
        let configURL = manager.configurationFileURL(for: sentinelID), pidURL = manager.pidFileURL(for: sentinelID)
        try Data("sentinel-config".utf8).write(to: configURL); try Data("sentinel-pid".utf8).write(to: pidURL)
        let ignored = try await manager.startOwned(profileID: sentinelID, node: node("ignore"))
        let closeStart = DispatchTime.now().uptimeNanoseconds
        try manager.requestStopOwned(ignored)
        try await Task.sleep(nanoseconds: 50_000_000)
        let unknown = try await manager.stopOwned(ignored, timeoutSeconds: 0.05)
        try check(unknown == nil && manager.pendingOwnedCount == 1, "unknown slot retained")
        do { _ = try await manager.startOwned(profileID: sentinelID, node: node("ignore")); throw Failure(label: "closing duplicate") } catch is SingboxProcessError { count += 1 }
        let repeated = try await manager.stopOwned(ignored, timeoutSeconds: 2)
        try check(repeated == nil && DispatchTime.now().uptimeNanoseconds - closeStart < 2_400_000_000, "single close budget")
        let allStart = DispatchTime.now().uptimeNanoseconds
        await manager.stopAllOwned(timeoutSeconds: 2)
        try check(DispatchTime.now().uptimeNanoseconds - allStart < 300_000_000, "stopAll joins elapsed budget")
        try await Task.sleep(nanoseconds: 2_300_000_000)
        try check(manager.pendingOwnedCount == 0, "late exit releases slot")
        let receipt = try await manager.stopOwned(ignored)
        try check(receipt != nil && receipt?.pid == ignored.pid, "late observed exit receipt")
        try manager.requestStopOwned(ignored)
        try check(try await manager.stopOwned(ignored) == receipt, "cached receipt stable")
        var alteredProxy = ignored.proxy; alteredProxy.port = alteredProxy.port == 65535 ? 65534 : alteredProxy.port + 1
        let alteredIdentity = SingboxProcessManager.OwnedIdentity(profileID: ignored.profileID, ownershipID: ignored.ownershipID, pid: ignored.pid, proxy: alteredProxy)
        do { try manager.requestStopOwned(alteredIdentity); throw Failure(label: "altered cached metadata") } catch SingboxProcessError.notRunning { count += 1 }
        do { _ = try await manager.stopOwned(alteredIdentity); throw Failure(label: "altered receipt metadata") } catch SingboxProcessError.notRunning { count += 1 }
        try check((try Data(contentsOf: configURL)) == Data("sentinel-config".utf8) && (try Data(contentsOf: pidURL)) == Data("sentinel-pid".utf8), "sentinels unchanged")
        try FileManager.default.removeItem(at: configURL); try FileManager.default.removeItem(at: pidURL); try FileManager.default.removeItem(at: manager.stateDirectory)
        do { _ = try await manager.startOwned(profileID: UUID(), node: node("timeout"), timeoutSeconds: 0.2); throw Failure(label: "timeout") } catch SingboxProcessError.startTimeout { count += 1 }
        let task = Task { try await manager.startOwned(profileID: UUID(), node: node("timeout"), timeoutSeconds: 5) }
        try await Task.sleep(nanoseconds: 100_000_000); task.cancel()
        do { _ = try await task.value; throw Failure(label: "cancel") } catch is CancellationError { count += 1 }
        let foreignID = UUID(), foreignPort = try manager.port(for: foreignID)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(label: "foreign socket") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(foreignPort).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw Failure(label: "foreign listen") }
        do { _ = try await manager.startOwned(profileID: foreignID, node: node("timeout"), timeoutSeconds: 0.25); close(fd); throw Failure(label: "foreign listener accepted") } catch SingboxProcessError.startTimeout { count += 1 }
        close(fd)
        let quarantined = root.appendingPathComponent("quarantined-helper")
        try FileManager.default.copyItem(at: helper, to: quarantined)
        let value = "0081;00000000;test;"
        let attrResult = value.withCString { setxattr(quarantined.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        guard attrResult == 0 else { throw Failure(label: "set quarantine") }
        let quarantinedManager = SingboxProcessManager(executableURL: quarantined, stateDirectory: manager.stateDirectory)
        do { _ = try await quarantinedManager.startOwned(profileID: UUID(), node: node("secret")); throw Failure(label: "quarantine accepted") } catch SingboxProcessError.quarantined { count += 1 }
        try check(getxattr(quarantined.path, "com.apple.quarantine", nil, 0, 0, 0) == value.utf8.count, "quarantine unchanged")
        try FileManager.default.removeItem(at: quarantined)
        do { _ = try await manager.startOwned(profileID: UUID(), node: node(String(repeating: "x", count: 1_048_576))); throw Failure(label: "oversized config") } catch SingboxProcessError.ownedConfigurationTooLarge { count += 1 }
        let blocked = root.appendingPathComponent("blocked-helper")
        try FileManager.default.copyItem(at: helper, to: blocked)
        let blockedManager = SingboxProcessManager(executableURL: blocked, stateDirectory: manager.stateDirectory)
        let before = DispatchTime.now().uptimeNanoseconds
        do { _ = try await blockedManager.startOwned(profileID: UUID(), node: node(String(repeating: "x", count: 500_000)), timeoutSeconds: 0.2); throw Failure(label: "blocked writer accepted") } catch SingboxProcessError.startTimeout { count += 1 }
        try check(DispatchTime.now().uptimeNanoseconds - before < 3_000_000_000, "blocked writer bounded")
        let blockedTask = Task { try await blockedManager.startOwned(profileID: UUID(), node: node(String(repeating: "x", count: 500_000)), timeoutSeconds: 5) }
        try await Task.sleep(nanoseconds: 100_000_000); blockedTask.cancel()
        do { _ = try await blockedTask.value; throw Failure(label: "blocked writer cancellation") } catch is CancellationError { count += 1 }
        try FileManager.default.removeItem(at: blocked)
        let raceManager = SingboxProcessManager(executableURL: helper, stateDirectory: manager.stateDirectory)
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        raceManager.ownedBeforeSpawn = { entered.signal(); resume.wait() }
        let raceID = UUID()
        let race = Task.detached { try await raceManager.startOwned(profileID: raceID, node: node("secret")) }
        guard await Task.detached(operation: { waitSignal(entered) }).value == .success else { resume.signal(); throw Failure(label: "race hook") }
        let startingPort = try raceManager.port(for: raceID)
        do { try raceManager.stop(profileID: raceID); resume.signal(); throw Failure(label: "legacy stop starting") } catch SingboxProcessError.notRunning { count += 1 }
        try check(try raceManager.port(for: raceID) == startingPort, "starting port retained")
        await raceManager.stopAllOwned(timeoutSeconds: 0.1)
        try check(raceManager.pendingOwnedCount == 1, "starting slot retained")
        resume.signal()
        do { _ = try await race.value; throw Failure(label: "starting survived stopAll") } catch is CancellationError { count += 1 }
        try check(raceManager.pendingOwnedCount == 0, "cancelled starting released")
        let spawnedManager = SingboxProcessManager(executableURL: helper, stateDirectory: manager.stateDirectory)
        let spawned = DispatchSemaphore(value: 0), registered = DispatchSemaphore(value: 0)
        spawnedManager.ownedAfterSpawn = { spawned.signal(); registered.wait() }
        let racingSpawn = Task.detached { try await spawnedManager.startOwned(profileID: UUID(), node: node("secret")) }
        guard await Task.detached(operation: { waitSignal(spawned) }).value == .success else { registered.signal(); throw Failure(label: "after spawn hook") }
        await spawnedManager.stopAllOwned(timeoutSeconds: 0.1)
        try check(spawnedManager.pendingOwnedCount == 1, "unregistered spawn retained")
        registered.signal()
        do { _ = try await racingSpawn.value; throw Failure(label: "spawn during stopAll") } catch is CancellationError { count += 1 }
        try check(spawnedManager.pendingOwnedCount == 0, "spawn during stopAll observed exit")
        let multi = SingboxProcessManager(executableURL: helper, stateDirectory: manager.stateDirectory)
        let first = try await multi.startOwned(profileID: UUID(), node: node("ignore"))
        let second = try await multi.startOwned(profileID: UUID(), node: node("ignore"))
        let multiStart = DispatchTime.now().uptimeNanoseconds
        await multi.stopAllOwned(timeoutSeconds: 2)
        try check(DispatchTime.now().uptimeNanoseconds - multiStart < 2_400_000_000, "stopAll total deadline")
        try check(multi.pendingOwnedCount == 2, "multi unknown retained")
        try await Task.sleep(nanoseconds: 2_300_000_000)
        try check(multi.pendingOwnedCount == 0, "multi late exit")
        let firstExit = try await multi.stopOwned(first), secondExit = try await multi.stopOwned(second)
        try check(firstExit != nil && secondExit != nil, "multi exit receipts")
        let boundaryManager = SingboxProcessManager(executableURL: helper, stateDirectory: manager.stateDirectory)
        let boundaryIdentity = try await boundaryManager.startOwned(profileID: UUID(), node: node("late"))
        let observing = DispatchSemaphore(value: 0), continueObservation = DispatchSemaphore(value: 0)
        boundaryManager.ownedBeforeCloseObserve = { observing.signal(); continueObservation.wait() }
        let boundaryTask = Task.detached { try await boundaryManager.stopOwned(boundaryIdentity, timeoutSeconds: 0.1) }
        guard await Task.detached(operation: { waitSignal(observing) }).value == .success else { continueObservation.signal(); throw Failure(label: "boundary hook") }
        try await Task.sleep(nanoseconds: 1_300_000_000)
        continueObservation.signal()
        let delayedResult = try await boundaryTask.value
        try check(delayedResult == nil, "late observed exit not timely")
        try check(boundaryManager.pendingOwnedCount == 0, "late exit cached")
        boundaryManager.ownedBeforeCloseObserve = nil
        try check(try await boundaryManager.stopOwned(boundaryIdentity) != nil, "cached late receipt remains available")
        let taskDeadlineManager = SingboxProcessManager(executableURL: helper, stateDirectory: manager.stateDirectory)
        let taskDeadlineIdentity = try await taskDeadlineManager.startOwned(profileID: UUID(), node: node("late"))
        let taskEntered = DispatchSemaphore(value: 0), taskResume = DispatchSemaphore(value: 0), taskDone = DispatchSemaphore(value: 0)
        let taskResult = ResultBox()
        taskDeadlineManager.ownedBeforeCloseTaskObserve = { taskEntered.signal(); taskResume.wait() }
        taskDeadlineManager.ownedDidCloseTaskObserve = { result in taskResult.set(result); taskDone.signal() }
        try taskDeadlineManager.requestStopOwned(taskDeadlineIdentity)
        guard await Task.detached(operation: { waitSignal(taskEntered) }).value == .success else { taskResume.signal(); throw Failure(label: "close task hook") }
        try await Task.sleep(nanoseconds: 2_200_000_000)
        taskResume.signal()
        guard await Task.detached(operation: { waitSignal(taskDone) }).value == .success else { throw Failure(label: "close task completion") }
        try check(taskResult.get() == nil, "late close task cannot publish timely exit")
        try check(taskDeadlineManager.pendingOwnedCount == 0, "late task actual exit cached")
        try check(try await taskDeadlineManager.stopOwned(taskDeadlineIdentity) != nil, "late task receipt available")
        let missingID = UUID()
        try FileManager.default.createDirectory(at: manager.stateDirectory, withIntermediateDirectories: true)
        let missingConfig = manager.configurationFileURL(for: missingID), missingPID = manager.pidFileURL(for: missingID)
        try Data("old".utf8).write(to: missingConfig); try Data("old".utf8).write(to: missingPID)
        do { try manager.stop(profileID: missingID); throw Failure(label: "missing legacy") } catch SingboxProcessError.notRunning { count += 1 }
        try check(!FileManager.default.fileExists(atPath: missingConfig.path) && !FileManager.default.fileExists(atPath: missingPID.path), "missing legacy cleanup")
        try FileManager.default.removeItem(at: manager.stateDirectory)
        return count
    }
}
