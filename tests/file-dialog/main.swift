import Foundation
import ApplicationServices

func require(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func fails(_ code: String, _ operation: () throws -> Void) {
    do { try operation(); require(false, "应拒绝 \(code)") }
    catch let failure as HelperFailure { require(failure.code == code, "错误类型应保留：\(code)") }
    catch { require(false, "意外错误") }
}
let target = TargetWindow(windowId: 100, pid: 200)
func sheet(_ id: UInt32, _ identifier: String, pid: Int32 = 200, role: String = "AXSheet") -> FileDialogIdentity {
    FileDialogIdentity(windowId: id, pid: pid, role: role, identifier: identifier)
}
let panel = sheet(101, "open-panel")
let go = sheet(102, "GoToWindow")
// Given 已授权主窗的原生 Open sheet，Then 仅接受该 sheet 或其 GoTo 子窗口持有焦点。
try verifyOwnedFileDialogFocus(target: target, panel: panel, goTo: nil, focused: panel)
try verifyOwnedFileDialogFocus(target: target, panel: panel, goTo: go, focused: go)
// Given 焦点已回网页、另一 Chrome 窗口或另一进程，Then 不发送路径或回车。
for focused in [sheet(100, ""), sheet(103, "open-panel"), sheet(101, "open-panel", pid: 201), sheet(0, "open-panel")] {
    fails("FILE_DIALOG_UNVERIFIED") { try verifyOwnedFileDialogFocus(target: target, panel: panel, goTo: nil, focused: focused) }
}
// Given ID 相同但不是原生 Open sheet，Then 不能扩大授权到任意对话框/页面节点。
for invalid in [sheet(101, "save-panel"), sheet(101, "open-panel", role: "AXGroup"), sheet(100, "open-panel"), sheet(101, "open-panel", pid: 201)] {
    fails("FILE_DIALOG_UNVERIFIED") { try verifyOwnedFileDialogFocus(target: target, panel: invalid, goTo: nil, focused: invalid) }
}
fails("FILE_DIALOG_UNVERIFIED") {
    try verifyOwnedFileDialogFocus(target: target, panel: panel, goTo: sheet(102, "unknown"), focused: go)
}
// Given 请求含绝对文件路径，Then 解码只保留原授权目标，无需帧或旧几何。
let base: [String: Any] = ["id": "file", "action": "select-file", "windowId": 100, "pid": 200]
var valid = base; valid["path"] = "/tmp/中文 文件.txt"
let decoded = try NativeRequest.decode(valid)
require(decoded.filePath == "/tmp/中文 文件.txt", "解码必须保留路径")
for path in ["", "relative.txt", "file:///tmp/a", "/tmp/../a", "/tmp/./a", "/tmp/a\n", "/tmp/", "/" + String(repeating: "字", count: 1400)] {
    var invalid = base; invalid["path"] = path
    fails("INVALID_ARGUMENT") { _ = try NativeRequest.decode(invalid) }
}
var geometry = valid; geometry["expectedBounds"] = ["x": 0, "y": 0, "width": 800, "height": 600]
fails("INVALID_ARGUMENT") { _ = try NativeRequest.decode(geometry) }
var unknown = valid; unknown["frameId"] = "page-frame"
fails("INVALID_ARGUMENT") { _ = try NativeRequest.decode(unknown) }
// Given 查询期间发生取消或超时，When 查询随后返回 ready，Then 不能返回成功。
for code in ["CANCELLED", "FILE_DIALOG_TIMEOUT"] {
    var valid = true
    fails(code) {
        try waitForFileDialog(check: {
            if !valid { throw HelperFailure(code: code, message: "等待期间状态已失效") }
        }, until: { valid = false; return true })
    }
}
print("PASS: 文件对话框焦点归属和路径协议 BDD 回归；未创建真实输入")

// Given 路径/焦点已满足且 AX 属性只读，Then 不重复写入，也不把只读错误当成选择失败。
var now: TimeInterval = 100
let cancellation = InputCancellation(clock: { now })
let lease = try cancellation.beginExecution(generation: 0)
require(cancellation.startCountdown(lease: lease), "启动测试倒计时")
now += 3
let permit = try cancellation.beginInput(generation: 0)
let selector = ChromeFileSelector(desktop: ChromeDesktop(), cancellation: cancellation)
var writes = 0
try selector.effect(permit, check: { try cancellation.checkInput(permit) }, unless: { true }) {
    writes += 1
    return .attributeUnsupported
}
require(writes == 0, "焦点已满足时不得写入只读属性")
// Given 状态不符，Then 仍执行原写入，且真实写入失败必须保留错误。
try selector.effect(permit, check: { try cancellation.checkInput(permit) }, unless: { false }) {
    writes += 1
    return .success
}
require(writes == 1, "状态不符时仍需写入")
fails("FILE_SELECTION_FAILED") {
    try selector.effect(permit, check: { try cancellation.checkInput(permit) }, unless: { false }) {
        writes += 1
        return .attributeUnsupported
    }
}
require(writes == 2, "真实写入错误不得被吞没")
// Given AX 查询跨过取消/超时，Then 即使返回状态已满足，也不能跳过校验。
for code in ["CANCELLED", "FILE_DIALOG_TIMEOUT"] {
    var expired = false
    fails(code) {
        try selector.effect(permit, check: {
            if expired { throw HelperFailure(code: code, message: "查询期间状态失效") }
        }, unless: { expired = true; return true }) {
            require(false, "状态失效不能产生副作用")
            return .success
        }
    }
}
// Given 用户已暂停，Then 状态已满足也不能被当作成功。
require(cancellation.pauseExecution(lease: lease), "测试暂停")
fails("USER_PAUSED") {
    try selector.effect(permit, check: { try cancellation.checkInput(permit) }, unless: { true }) {
        require(false, "暂停后不得写入")
        return .success
    }
}
print("PASS: 只读 AX 焦点幂等处理、必要写入、真实错误、取消/超时与用户暂停 BDD 回归")
