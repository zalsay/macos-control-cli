import XCTest
@testable import SafarierCore

final class RegistrationCloseDiagnosticTests: XCTestCase {
    func testExplicitAndReaderLeaseClosePreserveEOF() async throws {
        let root = try AutomationChannel.makePair()
        root.parent.labelRegistration(.rootManager)
        let other = try AutomationChannel(adopting: root.child)
        defer { other.close() }
        root.parent.close(); root.parent.close()
        XCTAssertFalse(root.parent.isLocallyOpen())
        let eof = try await AutomationChannelDeadline.run(channel: other, seconds: 1) { try await other.receive() }
        XCTAssertNil(eof)

        let leased = try AutomationChannel.makePair()
        leased.parent.labelRegistration(.rootRunner)
        let peer = try AutomationChannel(adopting: leased.child)
        defer { peer.close() }
        var reader: AutomationChannel.ReaderLease? = try leased.parent.claimExclusiveReader()
        XCTAssertNotNil(reader); reader = nil
        XCTAssertFalse(leased.parent.isLocallyOpen())
        leased.parent.close()
        let leaseEOF = try await AutomationChannelDeadline.run(channel: peer, seconds: 1) { try await peer.receive() }
        XCTAssertNil(leaseEOF)
    }
    func testChannelDeinitPreservesEOF() async throws {
        // A separately adopted endpoint with no outstanding queue jobs.
        let second = try AutomationChannel.makePair()
        var adopted: AutomationChannel? = try AutomationChannel(adopting: second.child)
        adopted!.labelRegistration(.generationManager)
        adopted = nil
        defer { second.parent.close() }
        let eof = try await AutomationChannelDeadline.run(channel: second.parent, seconds: 1) { try await second.parent.receive() }
        XCTAssertNil(eof)
    }
    func testCancellationStillClosesChannel() async throws {
        let pair = try AutomationChannel.makePair()
        pair.parent.labelRegistration(.generationRunner)
        let peer = try AutomationChannel(adopting: pair.child)
        defer { pair.parent.close(); peer.close() }
        let task = Task { try await pair.parent.receive() }
        task.cancel()
        _ = try? await task.value
        XCTAssertFalse(pair.parent.isLocallyOpen())
    }
    func testOperationErrorIsNotReportedAsDeadline() async throws {
        let pair = try AutomationChannel.makePair()
        pair.parent.labelRegistration(.generationManager)
        let peer = try AutomationChannel(adopting: pair.child)
        defer { pair.parent.close(); peer.close() }
        do {
            let _: Int = try await AutomationChannelDeadline.run(channel: pair.parent, seconds: 1) { throw HarnessError.eof }
            XCTFail("operation must reject")
        } catch {
            guard case HarnessError.eof = error else { return XCTFail("original error must be preserved") }
            XCTAssertFalse(pair.parent.isLocallyOpen())
        }
    }
    func testDeadlineStillClosesChannel() async throws {
        let pair = try AutomationChannel.makePair()
        pair.parent.labelRegistration(.generationManager)
        let peer = try AutomationChannel(adopting: pair.child)
        defer { pair.parent.close(); peer.close() }
        do {
            _ = try await AutomationChannelDeadline.run(channel: pair.parent, seconds: 0.02) { try await pair.parent.receive() }
            XCTFail("deadline must reject")
        } catch { XCTAssertFalse(pair.parent.isLocallyOpen()) }
    }
}
