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

// 自己的提示条移开后只能等待同步，不能把其他遮挡当作成功。
var timestamp: TimeInterval = 100, attempts = 0
try waitForPointerAfterToastMove(verify: {
    attempts += 1
    if attempts < 3 { throw HelperFailure(code: "POINTER_OBSCURED", message: "系统尚未同步提示条位置") }
}, clock: { timestamp }, sleep: { timestamp += $0 })
require(attempts == 3, "同步等待仍需重新校验，不能跳过失败")
expect("POINTER_OBSCURED") {
    try waitForPointerAfterToastMove(verify: { throw HelperFailure(code: "POINTER_OBSCURED", message: "持续被其他窗口遮挡") }, clock: { timestamp }, sleep: { timestamp += $0 })
}
for code in ["CANCELLED", "USER_PAUSED", "FOCUS_LOST"] {
    var calls = 0
    expect(code) {
        try waitForPointerAfterToastMove(verify: { calls += 1; throw HelperFailure(code: code, message: "动作已失效") }, clock: { timestamp }, sleep: { timestamp += $0 })
    }
    require(calls == 1, "取消/暂停/失焦不能作为位置同步自动重试")
}
print("PASS: 提示条移动后的只读同步等待、持续遮挡拒绝、取消/暂停/失焦不重试")

// 运行生产等待器，并在一次指针查询中改变实际InputCancellation，验证错误优先级与无重试。
for shouldCancel in [false, true] {
    var now: TimeInterval = 100
    let cancellation = InputCancellation(clock: { now })
    let lease = try cancellation.beginExecution(generation: 0)
    cancellation.startCountdown(lease: lease); now += 3
    let permit = try cancellation.beginInput(generation: 0)
    var count = 0
    expect(shouldCancel ? "CANCELLED" : "USER_PAUSED") {
        try waitForPointerAfterToastMove(check: { try cancellation.checkInput(permit) }, verify: {
            count += 1
            if shouldCancel { cancellation.cancel() } else { _ = cancellation.pauseExecution(lease: lease) }
            throw HelperFailure(code: "POINTER_OBSCURED", message: "查询仍命中旧提示条")
        }, clock: { now }, sleep: { now += $0 })
    }
    require(count == 1, "查询期间取消/暂停后不能重试或返回遮挡错误")
}
var focusLost = false, focusQueries = 0
expect("FOCUS_LOST") {
    try waitForPointerAfterToastMove(check: {
        if focusLost { throw HelperFailure(code: "FOCUS_LOST", message: "用户已切换应用") }
    }, verify: {
        focusQueries += 1; focusLost = true
        throw HelperFailure(code: "POINTER_OBSCURED", message: "旧指针归属")
    }, clock: { 0 }, sleep: { _ in })
}
require(focusQueries == 1, "焦点检查必须在重试闭包内感知状态变化")
print("PASS: 指针同步查询期间真实取消/暂停与失焦优先返回；不继续重试")
