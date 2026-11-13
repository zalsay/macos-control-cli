import Foundation
import SafarierCore

struct RunnerAutomationPageSnapshot: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "RunnerAutomationPageSnapshot(redacted)" }
    var debugDescription: String { description }
    let png: Data
    let viewport: AutomationViewport
    init(png: Data, viewport: AutomationViewport) { self.png = png; self.viewport = viewport }
}

@MainActor protocol RunnerAutomationPage: AnyObject {
    var identity: AutomationTargetIdentity { get }
    var onBlocked: ((BackgroundUIRequest) -> Void)? { get set }
    func viewport() throws -> AutomationViewport
    func readState(sessionState: AutomationSessionState, expectedViewport: AutomationViewport) throws -> AutomationState
    func perform(_ action: AutomationAction, expectedViewport: AutomationViewport) async throws -> AutomationResult
    func captureSnapshot(expectedViewport: AutomationViewport) async throws -> RunnerAutomationPageSnapshot
    func quiesceInput()
    func destroy() async -> Bool
    /// Return true only after native input is stopped and the original human
    /// window is restored. This must never close the borrowed window.
    func detachBorrowedControl() async -> Bool
    func prepareControlRelease() async throws
    func commitControlRelease() throws
    func finishControlRelease() throws
}

extension RunnerAutomationPage {
    func detachBorrowedControl() async -> Bool { false }
    func prepareControlRelease() async throws { throw AutomationError(code: .uiPolicyUnavailable) }
    func commitControlRelease() throws { throw AutomationError(code: .uiPolicyUnavailable) }
    func finishControlRelease() throws { throw AutomationError(code: .uiPolicyUnavailable) }
}
