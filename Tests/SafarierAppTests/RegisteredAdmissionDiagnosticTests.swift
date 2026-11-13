#if SAFARIER_BOUND_LOCAL_CANDIDATE
import XCTest
@testable import Safarier

final class RegisteredAdmissionDiagnosticTests: XCTestCase {
    func testFailureEmitsFixedReasonAndPreservesShortCircuit() {
        var reasons: [RegisteredAdmissionDiagnostic.Reason] = []
        var laterEvaluated = false
        let accepted = RegisteredAdmissionDiagnostic.check(false, .appActive, emit: { reasons.append($0) }) &&
            RegisteredAdmissionDiagnostic.check({ laterEvaluated = true; return true }(), .loading, emit: { reasons.append($0) })
        XCTAssertFalse(accepted)
        XCTAssertEqual(reasons, [.appActive])
        XCTAssertFalse(laterEvaluated)
    }
    func testSuccessDoesNotEmitFailure() {
        var reasons: [RegisteredAdmissionDiagnostic.Reason] = []
        XCTAssertTrue(RegisteredAdmissionDiagnostic.check(true, .loading, emit: { reasons.append($0) }))
        XCTAssertTrue(reasons.isEmpty)
    }
}
#endif
