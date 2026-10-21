import Foundation
import CoreGraphics

private func require(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
private func expect(_ code: String, _ operation: () throws -> Void) {
    do { try operation(); require(false, "应拒绝：\(code)") }
    catch let error as HelperFailure { require(error.code == code, "错误分类不符：\(error.code)") }
    catch { require(false, "返回非契约错误") }
}
let target = TargetWindow(windowId: 42, pid: 123)
let otherProcess = TargetWindow(windowId: 100, pid: 999)
let sameProcessOtherWindow = TargetWindow(windowId: 43, pid: 123)

// Given WindowServer 与 AX 均命中目标，Then 允许指针校验，不依赖上层绘制窗口数量。
try verifyPointerOwnership(target: target, eventTarget: { target }, accessibilityTarget: { target })

// Given 实际接收事件的是其他应用或同 Chrome 的其他窗口，Then 在任何输入前拒绝。
for hit in [otherProcess, sameProcessOtherWindow] {
    expect("POINTER_OBSCURED") {
        try verifyPointerOwnership(target: target, eventTarget: { hit }, accessibilityTarget: { target })
    }
    expect("POINTER_OBSCURED") {
        try verifyPointerOwnership(target: target, eventTarget: { target }, accessibilityTarget: { hit })
    }
}

// Given 只读查询失败或返回空身份，Then 不降级为只相信 AX 或忽略未知窗口。
var queriedAX = false
expect("POINTER_UNVERIFIED") {
    try verifyPointerOwnership(target: target, eventTarget: {
        throw HelperFailure(code: "POINTER_UNVERIFIED", message: "无法命中")
    }, accessibilityTarget: { queriedAX = true; return target })
}
require(!queriedAX, "系统目标无法确认时仍继续后续校验")
expect("POINTER_UNVERIFIED") {
    try verifyPointerOwnership(target: target, eventTarget: { TargetWindow(windowId: 0, pid: 0) }, accessibilityTarget: { target })
}

// Given AX 查询期间出现可拦截输入的浮层，Then 尾部 WindowServer 复核必须拒绝。
var changed = false
expect("POINTER_OBSCURED") {
    try verifyPointerOwnership(target: target, eventTarget: { changed ? otherProcess : target }, accessibilityTarget: {
        changed = true
        return target
    })
}
print("PASS: 指针归属 BDD：双源匹配、不同进程/窗口拒绝、查询失败关闭、校验期间新增遮挡拒绝；未创建窗口或发送输入")

// Given SPI 不可用的保守分支，Then 已覆盖目标点的可见窗口身份缺失时不能跳过。
let point = CGPoint(x: 100, y: 100)
let covered: [String: Any] = [kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 800, "Height": 600], kCGWindowAlpha as String: 1]
let targetInfo = covered.merging([kCGWindowNumber as String: UInt32(42), kCGWindowOwnerPID as String: Int32(123)]) { _, next in next }
let found = try conservativePointerTarget(at: point, windows: [targetInfo])
require(found.windowId == 42 && found.pid == 123, "保守路径无法识别直接命中的目标")
for patch: [String: Any] in [[:], [kCGWindowNumber as String: UInt32(100)], [kCGWindowOwnerPID as String: Int32(999)],
                              [kCGWindowNumber as String: "bad-id", kCGWindowOwnerPID as String: Int32(999)]] {
    let unknown = covered.merging(patch) { _, next in next }
    expect("POINTER_UNVERIFIED") { _ = try conservativePointerTarget(at: point, windows: [unknown, targetInfo]) }
}
print("PASS: SPI 缺失时的保守分支拒绝身份缺失/格式错误的前景窗口，不接受下层目标")
