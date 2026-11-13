#if SAFARIER_BOUND_LOCAL_CANDIDATE
import Foundation

enum RegisteredAdmissionDiagnostic {
    enum Reason: String {
        case session, targetSelection, targetNoGroup, targetMonitor, targetSelected, initialPresentation, loadingDeadline, attachTarget
        case appMissing, appActive, windowKey, windowMain, windowScreen, windowNumber, sheet
        case tabGroup, mouseButtons, loading, webViewWindow, navigationDelegate, uiDelegate
        case automationNavigation, startPage, addressFocus, editing, sessionLease, windowLease
        case inputAppActive, inputWindowKey, inputWindowMain, inputWebViewWindow, inputWindowNumber, presentation, inputPresentation
    }

    @discardableResult static func check(_ condition: @autoclosure () -> Bool, _ reason: Reason,
                                         emit: (Reason) -> Void = { fputs("REGISTERED_ADMISSION_DIAG reason=\($0.rawValue)\n", stderr) }) -> Bool {
        guard condition() else { emit(reason); return false }
        return true
    }
}
#endif
