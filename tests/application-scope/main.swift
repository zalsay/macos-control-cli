import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func fails(_ code: String, _ operation: () throws -> Void) {
    do { try operation(); require(false, "应拒绝 \(code)") }
    catch let failure as HelperFailure { require(failure.code == code, "错误码应保留 \(code)") }
    catch { require(false, "意外错误") }
}
let chrome = DesktopApplication(pid: 100, bundleId: "com.google.Chrome", name: "Chrome", regular: true)
let editor = DesktopApplication(pid: 101, bundleId: "com.apple.TextEdit", name: "TextEdit", regular: true)
let finder = DesktopApplication(pid: 102, bundleId: "com.apple.finder", name: "Finder", regular: true)
let background = DesktopApplication(pid: 103, bundleId: "com.apple.WindowManager", name: "System", regular: false)
require(chrome.allowed(in: .chrome), "旧入口支持Chrome")
require(!editor.allowed(in: .chrome) && !finder.allowed(in: .chrome), "旧入口不能被扩大到任意应用")
require(editor.allowed(in: .desktop) && finder.allowed(in: .desktop), "通用入口允许普通应用")
require(!background.allowed(in: .desktop), "不暴露后台系统进程")
let target = TargetWindow(windowId: 10, pid: 101, bundleId: "com.apple.TextEdit")
try verifyApplicationIdentity(target, application: editor, scope: .desktop)
fails("WINDOW_UNAVAILABLE") { try verifyApplicationIdentity(target, application: chrome, scope: .desktop) }
fails("WINDOW_UNAVAILABLE") {
    let replacement = DesktopApplication(pid: 101, bundleId: "com.other.app", name: "Other", regular: true)
    try verifyApplicationIdentity(target, application: replacement, scope: .desktop)
}
fails("WINDOW_UNAVAILABLE") { try verifyApplicationIdentity(TargetWindow(windowId: 10, pid: 101), application: editor, scope: .desktop) }
try verifyApplicationIdentity(TargetWindow(windowId: 10, pid: 100), application: chrome, scope: .chrome)
let base: [String: Any] = ["id": "desktop", "action": "window", "windowId": 10, "pid": 101, "bundleId": "com.apple.TextEdit"]
let decoded = try NativeRequest.decode(base, scope: .desktop)
require(decoded.target?.bundleId == "com.apple.TextEdit", "IPC保留固定应用身份")
fails("INVALID_ARGUMENT") { _ = try NativeRequest.decode(base) }
var missing = base; missing.removeValue(forKey: "bundleId")
fails("INVALID_ARGUMENT") { _ = try NativeRequest.decode(missing, scope: .desktop) }
var spoofed = base; spoofed["bundleId"] = "com.apple.TextEdit\n"
fails("INVALID_ARGUMENT") { _ = try NativeRequest.decode(spoofed, scope: .desktop) }
_ = try NativeRequest.decode(["id": "apps", "action": "apps"], scope: .desktop)
fails("UNKNOWN_ACTION") { _ = try NativeRequest.decode(["id": "apps", "action": "apps"]) }
print("PASS: 应用模式隔离、普通应用过滤、PID/bundle身份锁定、缺失身份/非法参数拒绝；未使用桌面输入")
