import AppKit

func require(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let screen = ChromeToastScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
let window = WindowBounds(x: 100, y: 100, width: 1000, height: 700)
let toolbar = WindowBounds(x: 100, y: 100, width: 1000, height: 86)
let frame = chromeToastToolbarFrame(window: window, toolbar: toolbar, screens: [screen])!
require(frame == CGRect(x: 320, y: 724, width: 560, height: 72), "只在目标窗口顶部区域居中，不能按屏幕居中")
let toolbarAppKit = CGRect(x: 100, y: 714, width: 1000, height: 86)
require(toolbarAppKit.contains(frame), "整个提示条必须落在原生顶部区域内")
let movedWindow = WindowBounds(x: 260, y: 170, width: 1000, height: 700)
let movedToolbar = WindowBounds(x: 260, y: 170, width: 1000, height: 86)
let moved = chromeToastToolbarFrame(window: movedWindow, toolbar: movedToolbar, screens: [screen])!
require(moved.origin.x - frame.origin.x == 160 && moved.origin.y - frame.origin.y == -70, "跟随窗口平移，不使用旧屏幕位置")
let point = CGPoint(x: frame.midX, y: screen.frame.maxY - frame.midY)
let avoided = chromeToastToolbarFrameAvoidingPointer(frame: frame, screenPoint: point, toolbar: toolbar, screens: [screen])
require(!avoided.contains(CGPoint(x: point.x, y: screen.frame.maxY - point.y)), "顶部有空间时必须横向避让目标")
require(avoided.minY == frame.minY && toolbarAppKit.contains(avoided), "不能避让到网页或屏幕底部")
require(!avoided.insetBy(dx: -16, dy: 0).contains(CGPoint(x: point.x, y: screen.frame.maxY - point.y)), "横向避让应留出原生窗口边缘安全间隙")
let narrow = WindowBounds(x: 100, y: 100, width: 360, height: 86)
let narrowFrame = chromeToastToolbarFrame(window: WindowBounds(x: 100, y: 100, width: 360, height: 600), toolbar: narrow, screens: [screen])!
let blocked = chromeToastToolbarFrameAvoidingPointer(frame: narrowFrame, screenPoint: CGPoint(x: narrowFrame.midX, y: 900 - narrowFrame.midY), toolbar: narrow, screens: [screen])
require(blocked == narrowFrame, "窄窗口无法避让时保留位置，交给原指针校验拒绝输入")
require(chromeToastToolbarFrame(window: window, toolbar: WindowBounds(x: 100, y: 190, width: 1000, height: 80), screens: [screen]) == nil, "不能把网页中间的矩形误当顶部区域")
require(chromeToastToolbarFrame(window: window, toolbar: WindowBounds(x: 100, y: 100, width: 1000, height: 30), screens: [screen]) == nil, "区域不足时不能侵入网页内容")
require(chromeToastOperationLabel(action: "type", key: "secret", clickCount: 1) == "输入文字", "不显示输入内容")
require(chromeToastOperationLabel(action: "select-file", key: "/private/path", clickCount: 1) == "选择文件", "不显示文件路径")
require(chromeToastOperationLabel(action: "click", key: "", clickCount: 2) == "双击", "显示真实操作类型")
require(chromeToastOperationLabel(action: "press", key: "Cmd+L", clickCount: 1) == "按键 Cmd+L", "显示白名单按键")
require(chromeToastOperationLabel(action: "press", key: "secret", clickCount: 1) == "按键", "非法按键不能进入提示文案")
let target = TargetWindow(windowId: 10, pid: 20, bundleId: "com.google.Chrome")
let prepared = ChromePreparedToastAnchor(target: target, anchor: ChromeToastAnchor(window: window, toolbar: toolbar))
require(prepared.forFileSelection(target: target, window: window, selecting: target) != nil, "专用文件选择动作可复用已验证顶部区域")
require(prepared.forFileSelection(target: target, window: window, selecting: nil) == nil, "普通操作不能使用模态提示缓存")
require(prepared.forFileSelection(target: target, window: movedWindow, selecting: target) == nil, "窗口几何改变后不能复用")
let other = TargetWindow(windowId: 11, pid: 20, bundleId: "com.google.Chrome")
require(prepared.forFileSelection(target: other, window: window, selecting: other) == nil, "不能复用另一个窗口的顶部区域")
let replaced = TargetWindow(windowId: 10, pid: 20, bundleId: "com.example.other")
require(prepared.forFileSelection(target: replaced, window: window, selecting: replaced) == nil, "不能复用替换应用的顶部区域")
let legacy = TargetWindow(windowId: 10, pid: 20)
require(prepared.forFileSelection(target: legacy, window: window, selecting: legacy) != nil, "原Chrome入口的省略bundle身份继续兼容")
var prime: [String: Any] = ["id": "prime", "action": "window", "windowId": 10, "pid": 20, "prepareToast": true]
let request = try NativeRequest.decode(prime)
require(request.prepareToast, "原生只读窗口查询可预读提示区域")
prime["prepareToast"] = "true"
do { _ = try NativeRequest.decode(prime); require(false, "prepareToast必须为严格bool") }
catch let error as HelperFailure { require(error.code == "INVALID_ARGUMENT", "非法prime类型应拒绝") }
print("PASS: Chrome顶部覆盖范围、窗口平移、横向避让、窄区域拒绝与操作文案不泄露 BDD")
