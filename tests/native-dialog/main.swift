import AppKit

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let target = TargetWindow(windowId: 77, pid: 123, bundleId: "com.tencent.xinWeChat")
let bounds = WindowBounds(x: 1540, y: 568, width: 360, height: 260)
let proof = NativeDialogIdentity(target: target, bounds: bounds, role: kAXWindowRole, subrole: kAXSystemDialogSubrole)
require(proof.matches(target: target, bounds: bounds), "AXSystemDialog 的精确原生身份可验证")
require(!proof.matches(target: TargetWindow(windowId: 78, pid: 123), bounds: bounds), "不能用同进程另一窗口替代")
require(!proof.matches(target: TargetWindow(windowId: 77, pid: 124), bounds: bounds), "不能用另一进程替代")
require(!proof.matches(target: target, bounds: WindowBounds(x: 1541, y: 568, width: 360, height: 260)), "不能放过位置漂移")
require(!proof.matches(target: target, bounds: WindowBounds(x: 1540, y: 568, width: 361, height: 260)), "不能放过尺寸漂移")
for role in ["AXWebArea", kAXButtonRole, kAXUnknownRole, ""] {
    require(!NativeDialogIdentity(target: target, bounds: bounds, role: role, subrole: kAXSystemDialogSubrole).matches(target: target, bounds: bounds),
            "网页或任意节点不能伪装为原生窗口")
}
for subrole in [kAXStandardWindowSubrole, kAXFloatingWindowSubrole, "", "AXUnknown"] {
    require(!NativeDialogIdentity(target: target, bounds: bounds, role: kAXWindowRole, subrole: subrole).matches(target: target, bounds: bounds),
            "未知或普通高层浮层不能按对话框放行")
}
for subrole in [kAXDialogSubrole, kAXSystemDialogSubrole] {
    require(NativeDialogIdentity(target: target, bounds: bounds, role: kAXWindowRole, subrole: subrole).matches(target: target, bounds: bounds),
            "只允许明确的原生对话框角色")
}
for scope in [DesktopScope.chrome, .desktop] {
    require(allowsWindowLayer(0, scope: scope, verifyNativeDialog: { fatalError("普通窗口不能新增 AX 授权依赖") }),
            "普通窗口保持旧行为")
}
require(allowsWindowLayer(23, scope: .desktop, verifyNativeDialog: { true }), "通用入口可接纳经过原生证明的层级23弹窗")
require(!allowsWindowLayer(23, scope: .desktop, verifyNativeDialog: { false }), "无法证明的弹窗拒绝")
require(!allowsWindowLayer(23, scope: .chrome, verifyNativeDialog: { fatalError("Chrome入口不能探测外部弹窗") }), "旧Chrome入口不扩大控制范围")
for layer in [-1, Int(CGWindowLevelForKey(.mainMenuWindow)), Int(CGWindowLevelForKey(.statusWindow)), Int.max] {
    require(!allowsWindowLayer(layer, scope: .desktop, verifyNativeDialog: { fatalError("菜单和系统层不能进入原生验证") }),
            "菜单/系统状态层以及异常层级拒绝")
}
print("PASS: 原生弹窗层级、模式隔离、PID/窗口ID/原生角色/严格几何与保守拒绝 BDD；未创建窗口或投递输入")

func fails(_ code: String, _ operation: () throws -> Void) {
    do { try operation(); require(false, "应拒绝 \(code)") }
    catch let error as HelperFailure { require(error.code == code, "应保留错误类型") }
    catch { require(false, "出现意外错误") }
}
let direct = try resolveAccessibilityPointerTarget(status: .success, windowServerHitAvailable: true, hitTarget: { target }, nativeDialogTarget: {
    fatalError("AX命中成功时不能采用后备证明")
})
require(direct.windowId == target.windowId, "正常AX命中保持旧行为")
let fallback = try resolveAccessibilityPointerTarget(status: .notImplemented, windowServerHitAvailable: true, hitTarget: {
    fatalError("未实现的AX点查询没有有效命中对象")
}, nativeDialogTarget: { target })
require(fallback.windowId == target.windowId, "仅对未实现的点查询允许原生窗口独立证明")
for status in [AXError.cannotComplete, .apiDisabled, .attributeUnsupported, .failure] {
    fails("POINTER_UNVERIFIED") {
        _ = try resolveAccessibilityPointerTarget(status: status, windowServerHitAvailable: true, hitTarget: { fatalError() }, nativeDialogTarget: {
            fatalError("权限/超时/其他查询失败不能被后备分支掩盖")
        })
    }
}
fails("POINTER_UNVERIFIED") {
    _ = try resolveAccessibilityPointerTarget(status: .notImplemented, windowServerHitAvailable: true, hitTarget: { fatalError() }, nativeDialogTarget: { nil })
}
fails("POINTER_OBSCURED") {
    try verifyPointerOwnership(target: target, eventTarget: { target }, accessibilityTarget: {
        try resolveAccessibilityPointerTarget(status: .success, windowServerHitAvailable: true, hitTarget: { TargetWindow(windowId: 78, pid: 123) }, nativeDialogTarget: {
            fatalError("AX真实命中别窗时不能回退")
        })
    })
}
fails("POINTER_OBSCURED") {
    try verifyPointerOwnership(target: target, eventTarget: { TargetWindow(windowId: 78, pid: 123) }, accessibilityTarget: {
        fatalError("SLS实际命中别窗时，原生后备也不能放行")
    })
}
print("PASS: 仅AX点查询notImplemented允许原生证明；权限/超时/真实别窗命中及SLS遮挡仍拒绝；未投递输入")

fails("POINTER_UNVERIFIED") {
    _ = try resolveAccessibilityPointerTarget(status: .notImplemented, windowServerHitAvailable: false,
        hitTarget: { fatalError() }, nativeDialogTarget: {
            fatalError("没有SLS实际命中能力时，不能同时缺少AX点命中")
        })
}

let legacyHit = try resolveAccessibilityPointerTarget(status: .success, windowServerHitAvailable: false,
    hitTarget: { target }, nativeDialogTarget: { fatalError("正常AX命中不走后备") })
require(legacyHit.windowId == target.windowId, "SLS不可用时保留原有CG+正常AX命中的保守路径")
print("PASS: AX点查询未实现时必须同时具有SLS实际命中能力；否则拒绝原生后备")
