import Foundation
import AppKit

enum DesktopScope { case chrome, desktop }

struct DesktopApplication {
    let pid: pid_t
    let bundleId: String
    let name: String
    let regular: Bool

    func allowed(in scope: DesktopScope) -> Bool {
        pid > 0 && !bundleId.isEmpty && regular && (scope == .desktop || bundleId == "com.google.Chrome")
    }
    var json: [String: Any] { ["pid": pid, "bundleId": bundleId, "name": name] }
}

func verifyApplicationIdentity(_ target: TargetWindow, application: DesktopApplication, scope: DesktopScope) throws {
    let expectedBundle = target.bundleId ?? (scope == .chrome ? "com.google.Chrome" : nil)
    guard application.allowed(in: scope), target.pid == application.pid,
          expectedBundle == application.bundleId else {
        throw HelperFailure(code: "WINDOW_UNAVAILABLE", message: "目标应用身份已失效，未扩大窗口控制范围")
    }
}
