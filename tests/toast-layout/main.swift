import Foundation

private func require(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let primary = ChromeToastScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
let right = ChromeToastScreen(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                              visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
let above = ChromeToastScreen(frame: CGRect(x: 0, y: 900, width: 1440, height: 900),
                              visibleFrame: CGRect(x: 0, y: 900, width: 1440, height: 875))
let left = ChromeToastScreen(frame: CGRect(x: -1280, y: 0, width: 1280, height: 800),
                             visibleFrame: CGRect(x: -1280, y: 0, width: 1280, height: 775))

// Given 主屏幕普通窗口，Then 提示在可见区域顶部居中并避让菜单栏。
let mainFrame = chromeToastFrame(window: WindowBounds(x: 100, y: 100, width: 800, height: 600), screens: [primary])
require(mainFrame == CGRect(x: 440, y: 715, width: 560, height: 80), "主屏幕 toast 位置错误")

// Given 跨屏窗口，Then 使用覆盖面积最大的屏幕，而非鼠标所在屏幕。
let spanning = chromeToastFrame(window: WindowBounds(x: 1300, y: 100, width: 800, height: 600), screens: [primary, right])
require(spanning == CGRect(x: 2120, y: 895, width: 560, height: 80), "跨屏 toast 没有落在目标窗口主屏幕")

// Given 副屏在主屏上方/左侧，Then 正确转换 CG 顶部原点和 AppKit 底部原点。
let upperFrame = chromeToastFrame(window: WindowBounds(x: 100, y: -800, width: 800, height: 600), screens: [primary, above])
require(upperFrame == CGRect(x: 440, y: 1615, width: 560, height: 80), "上方副屏坐标转换错误")
let leftFrame = chromeToastFrame(window: WindowBounds(x: -1100, y: 200, width: 800, height: 500), screens: [primary, left])
require(leftFrame == CGRect(x: -920, y: 615, width: 560, height: 80), "负坐标副屏位置错误")

// Given 很窄的屏幕，Then 提示仍位于可见区域内。
let narrow = ChromeToastScreen(frame: CGRect(x: 0, y: 0, width: 320, height: 700),
                               visibleFrame: CGRect(x: 0, y: 0, width: 320, height: 675))
let narrowFrame = chromeToastFrame(window: WindowBounds(x: 0, y: 0, width: 320, height: 700), screens: [narrow])
require(narrowFrame == CGRect(x: 16, y: 515, width: 288, height: 80), "窄屏 toast 超出可见区域")

// Given 无可用屏幕或目标在全部屏幕外，Then 不猜测显示位置。
require(chromeToastFrame(window: WindowBounds(x: 0, y: 0, width: 800, height: 600), screens: []) == nil, "无屏幕时应跳过 toast")
require(chromeToastFrame(window: WindowBounds(x: 5000, y: 0, width: 800, height: 600), screens: [primary]) == nil, "离屏目标不应在其他屏幕弹 toast")
print("PASS: 7 项 toast 布局 BDD 回归；未创建窗口或发送输入")

// Given 鼠标事件来源，Then 只忽略本 helper 和控制条区域，缺少 CG 读数时保守暂停。
require(!shouldPauseChromeForPointer(sourcePID: 42, helperPID: 42, insideControls: false), "本 helper 事件不应暂停")
require(shouldPauseChromeForPointer(sourcePID: 99, helperPID: 42, insideControls: false), "外部事件必须暂停")
require(shouldPauseChromeForPointer(sourcePID: nil, helperPID: 42, insideControls: false), "无 CG 读数应保守暂停")
require(shouldPauseChromeForPointer(sourcePID: 0, helperPID: 42, insideControls: false), "系统事件也应暂停")
for source: Int64? in [42, 99, nil] {
    require(!shouldPauseChromeForPointer(sourcePID: source, helperPID: 42, insideControls: true), "HUD 区域不应暂停")
}

// Given AI 目标落在顶部 HUD 内，Then 移到同屏底部，不改变尺寸也不隐藏。
let topHUD = mainFrame!
let bottomHUD = chromeToastFrameAvoidingPointer(frame: topHUD, screenPoint: CGPoint(x: 600, y: 145), screens: [primary])
require(bottomHUD == CGRect(x: 440, y: 80, width: 560, height: 80), "覆盖目标时未移到保留 80px 底部间距的位置")
require(chromeToastFrameAvoidingPointer(frame: bottomHUD, screenPoint: CGPoint(x: 600, y: 780), screens: [primary]) == topHUD,
        "底部 HUD 覆盖目标时未移回顶部")
require(chromeToastFrameAvoidingPointer(frame: topHUD, screenPoint: CGPoint(x: 10, y: 10), screens: [primary]) == topHUD,
        "不覆盖目标时不应移动 HUD")
let upperHUD = CGRect(x: 440, y: 1615, width: 560, height: 80)
require(chromeToastFrameAvoidingPointer(frame: upperHUD, screenPoint: CGPoint(x: 600, y: -755), screens: [primary, above]) ==
        CGRect(x: 440, y: 980, width: 560, height: 80), "上方副屏避让错误或移动到了主屏")
let leftHUD = CGRect(x: -920, y: 615, width: 560, height: 80)
require(chromeToastFrameAvoidingPointer(frame: leftHUD, screenPoint: CGPoint(x: -700, y: 245), screens: [primary, left]) ==
        CGRect(x: -920, y: 80, width: 560, height: 80), "负坐标副屏避让错误")
require(chromeToastFrameAvoidingPointer(frame: topHUD, screenPoint: CGPoint(x: 600, y: 145), screens: []) == topHUD,
        "未知屏幕时应保留 HUD，由完整指针 guard 拒绝被遮挡的输入")
// 两个垂直边缘仍覆盖目标时保持位置，不能挪到另一个仍会点击控制按钮的位置。
let shortScreen = ChromeToastScreen(frame: CGRect(x: 0, y: 0, width: 320, height: 240),
                                   visibleFrame: CGRect(x: 0, y: 0, width: 320, height: 240))
let overlappingHUD = CGRect(x: 16, y: 80, width: 288, height: 80)
require(chromeToastFrameAvoidingPointer(frame: overlappingHUD, screenPoint: CGPoint(x: 160, y: 60), screens: [shortScreen]) == overlappingHUD,
        "没有安全位置时应保留 HUD，让完整指针 guard 拒绝输入")
print("PASS: 鼠标来源分类与同屏双向避让 BDD；未创建窗口或发送输入")
