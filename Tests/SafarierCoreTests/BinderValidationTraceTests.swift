#if SAFARIER_BOUND_LOCAL_CANDIDATE
import XCTest
@testable import SafarierCore

final class BinderValidationTraceTests: XCTestCase {
    func testStaticStagesReportDurationAndFailureWithoutChangingErrors() throws {
        var now: UInt64 = 100
        var records: [(BinderValidationTrace.Checkpoint, BinderValidationTrace.Stage, UInt64, Bool)] = []
        let trace = BinderValidationTrace(checkpoint: .first, clock: { now }, sink: { records.append(($0, $1, $2, $3)) })
        trace.begin(.selfIdentity); now = 150; trace.success()
        trace.begin(.resources); now = 225
        enum TestFailure: Error { case expected }
        do {
            defer { trace.failureIfPending() }
            throw TestFailure.expected
        } catch {
            XCTAssertTrue(error is TestFailure)
        }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].0, .first); XCTAssertEqual(records[0].1, .selfIdentity)
        XCTAssertEqual(records[0].2, 50); XCTAssertTrue(records[0].3)
        XCTAssertEqual(records[1].1, .resources); XCTAssertEqual(records[1].2, 75); XCTAssertFalse(records[1].3)
        trace.failureIfPending()
        XCTAssertEqual(records.count, 2)
    }
}
#endif
