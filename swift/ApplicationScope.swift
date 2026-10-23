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

// 高层窗口必须由系统 AX 窗口对象证明身份，不能凭标题、绘制位置或网页节点放行。
struct NativeDialogIdentity {
    let target: TargetWindow
    let bounds: WindowBounds
    let role: String
    let subrole: String

    func matches(target expected: TargetWindow, bounds expectedBounds: WindowBounds) -> Bool {
        target.windowId > 0 && target.pid > 0 && target.windowId == expected.windowId && target.pid == expected.pid &&
            role == kAXWindowRole && [kAXDialogSubrole, kAXSystemDialogSubrole].contains(subrole) &&
            [bounds.x, bounds.y, bounds.width, bounds.height].allSatisfy(\.isFinite) &&
            bounds.width >= 50 && bounds.height >= 50 && bounds.matches(expectedBounds)
    }
}

func allowsWindowLayer(_ layer: Int, scope: DesktopScope, verifyNativeDialog: () -> Bool) -> Bool {
    if layer == 0 { return true }
    // 不扩大旧 Chrome 入口，也不把菜单、状态栏、系统遮罩等层级纳入通用控制。
    guard scope == .desktop, layer > 0, layer < Int(CGWindowLevelForKey(.mainMenuWindow)) else { return false }
    return verifyNativeDialog()
}
