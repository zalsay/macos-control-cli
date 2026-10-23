import AppKit

// 只拥有本进程的隔离窗口；测试按钮记录结果，不访问网络、用户应用或文件。
final class DialogPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class DialogButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
final class Fixture: NSObject, NSApplicationDelegate {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    var main: NSWindow!
    var dialog: DialogPanel!
    var timer: Timer?
    var excluded: [NSPanel] = []
    var cover: NSPanel?
    var clicks = 0
    func write(_ name: String, _ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try! data.write(to: root.appendingPathComponent(name), options: .atomic)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        main = NSWindow(contentRect: NSRect(x: 1350, y: 300, width: 600, height: 450),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        main.title = "NativeDialogFixture main"
        main.orderFront(nil)
        dialog = DialogPanel(contentRect: NSRect(x: 1450, y: 380, width: 360, height: 260),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        dialog.title = "NativeDialogFixture authorization"
        dialog.level = NSWindow.Level(rawValue: 23)
        dialog.setAccessibilitySubrole(.systemDialog)
        dialog.hidesOnDeactivate = false
        let label = NSTextField(labelWithString: "独立授权弹窗回归")
        label.frame = NSRect(x: 24, y: 170, width: 300, height: 30)
        dialog.contentView!.addSubview(label)
        let button = DialogButton(title: "允许测试", target: self, action: #selector(allow(_:)))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 180, y: 30, width: 150, height: 36)
        dialog.contentView!.addSubview(button)
        dialog.orderFrontRegardless()
        // 同一普通应用里的菜单层、状态层和非对话框浮层不能因新能力一起被放行。
        for (index, item) in [(23, NSAccessibility.Subrole.standardWindow), (24, .systemDialog), (25, .systemDialog)].enumerated() {
            let panel = DialogPanel(contentRect: NSRect(x: 2050 + index * 50, y: 400, width: 200, height: 180),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: item.0)
            panel.setAccessibilitySubrole(item.1)
            panel.hidesOnDeactivate = false
            panel.orderFrontRegardless()
            excluded.append(panel)
        }
        write("fixture.json", ["pid": ProcessInfo.processInfo.processIdentifier,
                              "mainWindowId": main.windowNumber, "dialogWindowId": dialog.windowNumber,
                              "excludedWindowIds": excluded.map(\.windowNumber)])
        write("clicks.json", ["clicks": clicks])
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.cover == nil, FileManager.default.fileExists(atPath: self.root.appendingPathComponent("cover.trigger").path) {
                let panel = DialogPanel(contentRect: self.dialog.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.level = NSWindow.Level(rawValue: 24)
                panel.backgroundColor = .windowBackgroundColor
                panel.hidesOnDeactivate = false
                panel.orderFrontRegardless()
                self.cover = panel
                self.write("cover.json", ["windowId": panel.windowNumber])
            }
            if FileManager.default.fileExists(atPath: self.root.appendingPathComponent("dialog.close").path) {
                self.dialog.orderOut(nil)
                self.cover?.orderOut(nil)
                self.write("closed.json", ["closed": true])
            }
            if FileManager.default.fileExists(atPath: self.root.appendingPathComponent("fixture.stop").path) { NSApplication.shared.terminate(nil) }
        }
    }
    @objc func allow(_ sender: NSButton) { clicks += 1; write("clicks.json", ["clicks": clicks]) }
}
let app = NSApplication.shared
_ = app.setActivationPolicy(.regular)
let fixture = Fixture()
app.delegate = fixture
app.run()
