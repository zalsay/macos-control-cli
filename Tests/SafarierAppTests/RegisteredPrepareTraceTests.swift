#if SAFARIER_BOUND_LOCAL_CANDIDATE
import XCTest
@testable import Safarier

final class RegisteredPrepareTraceTests: XCTestCase {
    func testFailureReportsOnlyCurrentFixedPhaseAndPreservesError() {
        enum Marker: Error { case denied }
        var events: [String] = []
        let trace = RegisteredPrepareTrace { phase, result, _ in events.append("\(phase.rawValue):\(result.rawValue)") }
        func run() throws {
            defer { trace.failureIfPending() }
            trace.begin(.identity); trace.success()
            trace.begin(.profile)
            throw Marker.denied
        }
        XCTAssertThrowsError(try run()) { XCTAssertTrue($0 is Marker) }
        XCTAssertEqual(events, ["identity:ok", "profile:error"])
    }
    func testSuccessfulPhasesDoNotReportFailureOnCleanup() {
        var events: [String] = []
        let trace = RegisteredPrepareTrace { phase, result, _ in events.append("\(phase.rawValue):\(result.rawValue)") }
        trace.begin(.plan); trace.success(); trace.failureIfPending()
        XCTAssertEqual(events, ["plan:ok"])
    }
}
#endif
