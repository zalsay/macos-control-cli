import AppKit
import SafarierCore

@MainActor
final class ManagerMenu: NSObject, NSMenuItemValidation {
    private let model: ManagerModel
    init(model: ManagerModel) { self.model = model; super.init() }

    func make() -> NSMenu {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String = "", _ flags: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let result = NSMenuItem(title: title, action: action, keyEquivalent: key)
            result.keyEquivalentModifierMask = key.isEmpty ? [] : flags
            return result
        }
        func submenu(_ title: String) -> NSMenu {
            let menu = NSMenu(title: title); let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = menu; main.addItem(parent); return menu
        }
        let app = submenu("Safarier AI")
        app.addItem(item("关于 Safarier AI", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        let jev = item("JEV 模型配置…", #selector(openJEVConfig(_:)), ",")
        jev.target = self; app.addItem(jev)
        app.addItem(.separator())
        let services = NSMenu(title: "服务"); let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        servicesItem.submenu = services; app.addItem(servicesItem); NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(item("隐藏 Safarier AI", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item("全部显示", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator()); app.addItem(item("退出 Safarier AI", #selector(NSApplication.terminate(_:)), "q"))
        let file = submenu("文件")
        let edit = submenu("编辑")
        edit.addItem(item("撤销", Selector(("undo:")), "z")); edit.addItem(item("重做", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("剪切", #selector(NSText.cut(_:)), "x")); edit.addItem(item("拷贝", #selector(NSText.copy(_:)), "c")); edit.addItem(item("粘贴", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("粘贴并匹配样式", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        edit.addItem(item("删除", #selector(NSText.delete(_:))))
        edit.addItem(item("全选", #selector(NSText.selectAll(_:)), "a"))
        func nested(_ title: String, in parent: NSMenu) -> NSMenu {
            let result = NSMenu(title: title); let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            entry.submenu = result; parent.addItem(entry); return result
        }
        edit.addItem(.separator())
        let find = nested("查找", in: edit)
        for (title, key, flags, tag) in [
            ("查找…", "f", NSEvent.ModifierFlags.command, NSFindPanelAction.showFindPanel),
            ("查找下一个", "g", NSEvent.ModifierFlags.command, NSFindPanelAction.next),
            ("查找上一个", "g", NSEvent.ModifierFlags([.command, .shift]), NSFindPanelAction.previous),
            ("使用所选内容查找", "e", NSEvent.ModifierFlags.command, NSFindPanelAction.setFindString),
        ] {
            let entry = item(title, #selector(NSTextView.performFindPanelAction(_:)), key, flags)
            entry.tag = Int(tag.rawValue); find.addItem(entry)
        }
        let spelling = nested("拼写和语法", in: edit)
        spelling.addItem(item("显示拼写和语法", #selector(NSText.showGuessPanel(_:)), ":", [.command, .shift]))
        spelling.addItem(item("立即检查文稿", #selector(NSText.checkSpelling(_:)), ";"))
        spelling.addItem(.separator())
        spelling.addItem(item("键入时检查拼写", #selector(NSTextView.toggleContinuousSpellChecking(_:))))
        spelling.addItem(item("检查拼写时检查语法", #selector(NSTextView.toggleGrammarChecking(_:))))
        spelling.addItem(item("自动更正拼写", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))))
        let replacements = nested("替换", in: edit)
        replacements.addItem(item("智能拷贝/粘贴", #selector(NSTextView.toggleSmartInsertDelete(_:))))
        replacements.addItem(item("智能引号", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))))
        replacements.addItem(item("智能连字符", #selector(NSTextView.toggleAutomaticDashSubstitution(_:))))
        replacements.addItem(item("智能链接", #selector(NSTextView.toggleAutomaticLinkDetection(_:))))
        replacements.addItem(item("文本替换", #selector(NSTextView.toggleAutomaticTextReplacement(_:))))
        let transform = nested("转换", in: edit)
        transform.addItem(item("转换为大写", #selector(NSResponder.uppercaseWord(_:))))
        transform.addItem(item("转换为小写", #selector(NSResponder.lowercaseWord(_:))))
        transform.addItem(item("首字母大写", #selector(NSResponder.capitalizeWord(_:))))
        let speech = nested("语音", in: edit)
        speech.addItem(item("开始朗读", #selector(NSTextView.startSpeaking(_:))))
        speech.addItem(item("停止朗读", #selector(NSTextView.stopSpeaking(_:))))
        let view = submenu("显示")
        view.addItem(item("进入全屏幕", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        view.addItem(.separator())
        let environment = submenu("环境")
        let window = submenu("窗口")
        window.addItem(item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("缩放", #selector(NSWindow.performZoom(_:))))
        window.addItem(item("关闭窗口", #selector(NSWindow.performClose(_:)), "w"))
        window.addItem(.separator())
        window.addItem(item("前置全部窗口", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window
        for entry in ManagerMenuDefinition.commands {
            let menu: NSMenu
            switch entry.command {
            case .newProfile, .newSubscription: menu = file
            case .toggleSidebar: menu = view
            case .cycle: menu = window
            default: menu = environment
            }
            if entry.command == .refresh { menu.addItem(.separator()) }
            if entry.command == .cycle { menu.addItem(.separator()) }
            var flags: NSEvent.ModifierFlags = .command
            if entry.shift { flags.insert(.shift) }; if entry.control { flags.insert(.control) }
            let action = entry.command == .toggleSidebar ? #selector(NSSplitViewController.toggleSidebar(_:)) : #selector(performCommand(_:))
            let menuItem = item(entry.title, action, entry.key, flags)
            if entry.command != .toggleSidebar { menuItem.target = self; menuItem.representedObject = entry.command.rawValue }
            menu.addItem(menuItem)
        }
        return main
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(openJEVConfig(_:)) { return model.sheet == nil }
        guard let raw = item.representedObject as? String, let command = ManagerMenuCommand(rawValue: raw) else { return true }
        if model.sheet != nil && [.newProfile, .newSubscription, .edit].contains(command) { return false }
        let profile = model.selectedProfile
        return ManagerMenuDefinition.enabled(command, context: ManagerMenuContext(hasSelectedProfile: profile != nil, selectedProfileStopped: profile.map { model.runState($0.id) == .stopped } ?? false, hasSubscriptions: !model.subscriptions.isEmpty))
    }
    @objc private func openJEVConfig(_ item: NSMenuItem) {
        guard model.sheet == nil else { return }
        model.sheet = .jevConfig
    }
    @objc private func performCommand(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let command = ManagerMenuCommand(rawValue: raw), validateMenuItem(item) else { return }
        switch command {
        case .newProfile: model.sheet = .newProfile
        case .newSubscription: model.sheet = .newSubscription
        case .launch: if let profile = model.selectedProfile { model.launch(profile) }
        case .edit: if let profile = model.selectedProfile { model.sheet = .editProfile(profile) }
        case .duplicate: if let profile = model.selectedProfile { _ = model.duplicate(profile) }
        case .refresh: model.refreshAllSubscriptions()
        case .reload: model.reload()
        case .cycle: if !WindowCycler.activateOtherSafarier(forward: true) { NSSound.beep() }
        case .toggleSidebar: break
        }
    }
}
