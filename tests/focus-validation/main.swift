import Foundation

private func require(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
private func expectFailure(_ code: String, _ operation: () throws -> Void) {
    do {
        try operation()
        require(false, "校验未拒绝：\(code)")
    } catch let failure as HelperFailure {
        require(failure.code == code, "未保留具体的焦点或几何错误")
    } catch { require(false, "返回意外错误") }
}

// fake 仅替代系统焦点读数；运行生产校验流程，全程不创建或发送输入事件。
private func checkedWindow(pid: Int, window: Int, available: Bool = true) throws -> Int {
    guard available else { throw HelperFailure(code: "FOCUS_UNVERIFIED", message: "无焦点读数") }
    guard pid == 123, window == 456 else { throw HelperFailure(code: "FOCUS_LOST", message: "目标焦点已变化") }
    return window
}

// Given 两次焦点一致且几何稳定，Then 接受输入前校验。
try verifyStableWindowFocus(requireTargetFocus: { try checkedWindow(pid: 123, window: 456) }, verifyGeometry: {
    require($0 == 456, "几何检查必须针对已验证窗口")
})

// Given 耗时检查期间切换到同一 Chrome 的其他窗口，Then 尾部复核必须拒绝。
var focusedWindow = 456
expectFailure("FOCUS_LOST") {
    try verifyStableWindowFocus(requireTargetFocus: { try checkedWindow(pid: 123, window: focusedWindow) }, verifyGeometry: { _ in
        focusedWindow = 789
    })
}

// Given 耗时检查期间切换到其他应用，Then 保留旧 focusedWindow 也不能通过。
var focusedPID = 123
expectFailure("FOCUS_LOST") {
    try verifyStableWindowFocus(requireTargetFocus: { try checkedWindow(pid: focusedPID, window: 456) }, verifyGeometry: { _ in
        focusedPID = 999
    })
}

// Given 尾部查询无法确认，Then 不把之前成功的状态当成最终结果。
var available = true
expectFailure("FOCUS_UNVERIFIED") {
    try verifyStableWindowFocus(requireTargetFocus: { try checkedWindow(pid: 123, window: 456, available: available) }, verifyGeometry: { _ in
        available = false
    })
}

// Given 几何检查失败，Then 原错误向上传递。
expectFailure("IMAGE_GEOMETRY_CHANGED") {
    try verifyStableWindowFocus(requireTargetFocus: { try checkedWindow(pid: 123, window: 456) }, verifyGeometry: { _ in
        throw HelperFailure(code: "IMAGE_GEOMETRY_CHANGED", message: "几何变化")
    })
}

// Given 首次焦点已失效，Then 不继续后续几何检查。
var geometryChecked = false
expectFailure("FOCUS_LOST") {
    try verifyStableWindowFocus(requireTargetFocus: { try checkedWindow(pid: 999, window: 456) }, verifyGeometry: { _ in
        geometryChecked = true
    })
}
require(!geometryChecked, "首次焦点失败后仍执行了后续操作")
print("PASS: 6 项纯 fake 焦点与几何 BDD 回归；未调用真实 AX 或输入事件")
