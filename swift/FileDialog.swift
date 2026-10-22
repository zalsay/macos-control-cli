import Foundation
import AppKit
import ApplicationServices

struct FileDialogIdentity {
    let windowId: CGWindowID
    let pid: pid_t
    let role: String
    let identifier: String
}

// 身份来自已授权主窗口的原生 sheet 子节点，绝不接受其他 Chrome 窗口或任意系统对话框。
func verifyOwnedFileDialogFocus(target: TargetWindow, panel: FileDialogIdentity,
                               goTo: FileDialogIdentity?, focused: FileDialogIdentity) throws {
    func valid(_ sheet: FileDialogIdentity, identifier: String) -> Bool {
        sheet.pid == target.pid && sheet.windowId > 0 && sheet.windowId != target.windowId &&
            sheet.role == kAXSheetRole && sheet.identifier == identifier
    }
    guard valid(panel, identifier: "open-panel"),
          goTo.map({ valid($0, identifier: "GoToWindow") && $0.windowId != panel.windowId }) ?? true,
          focused.pid == target.pid, focused.role == kAXSheetRole,
          (focused.windowId == panel.windowId && focused.identifier == "open-panel") ||
            (goTo.map { focused.windowId == $0.windowId && focused.identifier == "GoToWindow" } ?? false) else {
        throw HelperFailure(code: "FILE_DIALOG_UNVERIFIED", message: "无法确认焦点属于已授权 Chrome 窗口的文件选择框")
    }
}

func waitForFileDialog(check: () throws -> Void, until ready: () throws -> Bool) throws {
    while true {
        try check()
        let isReady = try ready()
        // AX 查询可能跨过取消或截止点；查询结束后也必须检查，不能把迟到结果当成功。
        try check()
        if isReady { return }
        Thread.sleep(forTimeInterval: 0.04)
    }
}


final class ChromeFileSelector {
    private let desktop: ChromeDesktop
    private let cancellation: InputCancellation

    init(desktop: ChromeDesktop, cancellation: InputCancellation) {
        self.desktop = desktop; self.cancellation = cancellation
    }

    func select(_ request: NativeRequest, generation: UInt64) throws -> [String: Any] {
        guard let target = request.target else { throw HelperFailure.invalidArgument }
        guard (target.bundleId ?? "com.google.Chrome") == "com.google.Chrome" else {
            throw HelperFailure(code: "FILE_DIALOG_UNSUPPORTED", message: "该应用尚无已验证的文件选择适配，请勿向未知原生对话框发送输入")
        }
        // 不读取文件内容。原生层再次校验，避免绕过 CLI 直接调用 helper 时选择目录或无效路径。
        let file = URL(fileURLWithPath: request.filePath).resolvingSymlinksInPath()
        guard file.path.utf8.count <= 4096,
              !file.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true,
              FileManager.default.isReadableFile(atPath: file.path) else {
            throw HelperFailure(code: "FILE_NOT_READABLE", message: "请选择存在且可读取的普通文件")
        }
        desktop.setSelectingFile(target, active: true)
        defer { desktop.setSelectingFile(target, active: false) }
        let permit = try desktop.prepareInput(target, cancellation: cancellation, generation: generation, expectedEpoch: request.inputEpoch, operation: chromeToastOperationLabel(action: "select-file"))
        var completed = false
        defer { desktop.updateOperation(target, finished: true, succeeded: completed, cancellation: cancellation, generation: generation) }
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        func check() throws {
            try cancellation.checkInput(permit)
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw HelperFailure(code: "FILE_DIALOG_TIMEOUT", message: "文件选择框未在限定时间内完成，请检查对话框后重试")
            }
        }
        let app = desktop.axApplication(target.pid)
        let bounds = try desktop.window(target).bounds
        // 后台 Chrome 的 AppKit modal 可能不响应 AXWindows；这是输入操作，先激活已验证的原应用再查询 sheet。
        try desktop.activateApplication(target, cancellation: cancellation, generation: generation, permit: permit)
        func resolveRoot() throws -> AXUIElement {
            try check()
            _ = try desktop.window(target)
            // AppKit 首次建立 AX 连接时可能暂时取不到窗口；只重读精确 ID，不产生桌面副作用。
            let queryDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
            while true {
                do {
                    return try desktop.targetAXWindow(target, app: app)
                } catch let failure as HelperFailure where failure.code == "FOCUS_UNVERIFIED" && ProcessInfo.processInfo.systemUptime < queryDeadline {
                    try check()
                    Thread.sleep(forTimeInterval: 0.04)
                }
            }
        }
        // 单次动作固定已验证的 AX 主窗引用，避免 modal 切换期间反复枚举 AXWindows。
        let axRoot = try resolveRoot()
        func root() throws -> AXUIElement {
            try check()
            _ = try desktop.window(target)
            guard desktop.identifier(axRoot) == target.windowId else {
                throw HelperFailure(code: "FILE_DIALOG_UNVERIFIED", message: "原 Chrome 辅助功能窗口身份已失效")
            }
            return axRoot
        }
        func sheets(_ root: AXUIElement) throws -> [AXUIElement] {
            // AXSheets 在部分 Chrome/AppKit 版本为空；原生 sheet 归属以主窗口 AXChildren 为准。
            let children = try self.children(root, required: true)
            return children.filter { self.string($0, kAXRoleAttribute) == kAXSheetRole }
        }
        let initialSheets = try sheets(root())
        let panels = initialSheets.filter { string($0, kAXIdentifierAttribute) == "open-panel" }
        guard panels.count == 1, let panel = panels.first, let panelID = desktop.identifier(panel) else {
            throw HelperFailure(code: panels.isEmpty ? "FILE_DIALOG_NOT_FOUND" : "FILE_DIALOG_UNVERIFIED",
                                message: "已授权 Chrome 窗口没有唯一可确认的原生文件选择框，请先点击网页上传按钮")
        }
        func state() throws -> (panel: AXUIElement, goTo: AXUIElement?) {
            let rootSheets = try sheets(root())
            guard let current = rootSheets.first(where: { desktop.identifier($0) == panelID && string($0, kAXIdentifierAttribute) == "open-panel" }) else {
                throw HelperFailure(code: "FILE_DIALOG_UNVERIFIED", message: "原文件选择框已关闭或被替换，已停止选择文件")
            }
            let goSheets = (rootSheets + (try sheets(current))).filter { string($0, kAXIdentifierAttribute) == "GoToWindow" }
            var unique: [AXUIElement] = []
            for sheet in goSheets where !unique.contains(where: { CFEqual($0, sheet) }) { unique.append(sheet) }
            guard unique.count <= 1 else { throw unsupported() }
            let goTo = unique.first
            let focused = try desktop.frontmostAXWindow(target, app: app)
            try verifyOwnedFileDialogFocus(target: target, panel: identity(current), goTo: goTo.map(identity), focused: identity(focused))
            _ = try desktop.window(target)
            try check()
            return (current, goTo)
        }
        func settledState() throws -> (panel: AXUIElement, goTo: AXUIElement?)? {
            do { return try state() }
            catch let failure as HelperFailure where ["FILE_DIALOG_UNVERIFIED", "FOCUS_UNVERIFIED"].contains(failure.code) {
                // 原生 sheet 的焦点与子树分批更新；只在预期切换的只读等待中重查，不发送输入。
                return nil
            }
        }
        // 仅提升原主窗口；附属 modal sheet 自己取得焦点，绝不把焦点强制写回网页。
        let original = try root()
        try effect(permit, check: check) { AXUIElementPerformAction(original, kAXRaiseAction as CFString) }
        let focusDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 1.5)
        var focusFailure: HelperFailure?
        try waitForFileDialog(check: {
            try check()
            if ProcessInfo.processInfo.systemUptime >= focusDeadline {
                throw focusFailure ?? HelperFailure(code: "FOCUS_UNVERIFIED", message: "激活后仍无法确认原生文件选择框焦点")
            }
        }, until: {
            do { _ = try state(); return true }
            catch let failure as HelperFailure where ["FOCUS_LOST", "FOCUS_UNVERIFIED", "FILE_DIALOG_UNVERIFIED"].contains(failure.code) {
                focusFailure = failure
                return false
            }
        })
        try desktop.showOperationToast(target, bounds: bounds, cancellation: cancellation, generation: generation)
        func key(_ code: CGKeyCode, flags: CGEventFlags = [], verify: () throws -> Void) throws {
            try verify()
            guard let source = CGEventSource(stateID: .privateState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
                throw HelperFailure(code: "INPUT_FAILED", message: "系统未能创建文件选择快捷键")
            }
            down.flags = flags; up.flags = []
            try check()
            let held = try cancellation.keyDown(down, release: up, permit: permit)
            defer { cancellation.release(held) }
            Thread.sleep(forTimeInterval: 0.008)
            try check()
        }
        if try state().goTo == nil {
            try key(5, flags: [.maskCommand, .maskShift]) {
                guard try state().goTo == nil else { throw self.unsupported() }
            }
        }
        var field: AXUIElement?
        try waitForFileDialog(check: check) {
            guard let current = try settledState(), let go = current.goTo else { return false }
            field = try self.find(go, identifier: "PathTextField", role: kAXTextFieldRole, check: check)
            return field != nil
        }
        guard let field, let goTo = try state().goTo, let goToID = desktop.identifier(goTo) else { throw unsupported() }
        func verifyPathField() throws {
            guard let current = try state().goTo, desktop.identifier(current) == goToID,
                  let currentField = try self.find(current, identifier: "PathTextField", role: kAXTextFieldRole, check: check),
                  CFEqual(currentField, field) else { throw self.unsupported() }
        }
        try verifyPathField()
        try effect(permit, check: check, unless: { self.string(field, kAXValueAttribute) == file.path }) {
            AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, file.path as CFString)
        }
        try verifyPathField()
        try effect(permit, check: check, unless: { self.bool(field, kAXFocusedAttribute) == true }) {
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        try verifyPathField()
        // 部分 AppKit 面板的应用级焦点属性只读；焦点已指向目标字段时不能重复写入。
        try effect(permit, check: check, unless: {
            self.desktop.elementAttribute(app, kAXFocusedUIElementAttribute).map { CFEqual($0, field) } ?? false
        }) {
            AXUIElementSetAttributeValue(app, kAXFocusedUIElementAttribute as CFString, field)
        }
        try waitForFileDialog(check: check) { self.string(field, kAXValueAttribute) == file.path && self.bool(field, kAXFocusedAttribute) == true }
        try key(36) {
            try verifyPathField()
            guard self.string(field, kAXValueAttribute) == file.path, self.bool(field, kAXFocusedAttribute) == true,
                  let focused = self.desktop.elementAttribute(app, kAXFocusedUIElementAttribute), CFEqual(focused, field),
                  self.desktop.identifier(try self.desktop.frontmostAXWindow(target, app: app)) == goToID else {
                throw self.unsupported()
            }
        }
        var openButton: AXUIElement?
        try waitForFileDialog(check: check) {
            guard let current = try settledState(), current.goTo == nil else { return false }
            openButton = try self.find(current.panel, identifier: "OKButton", role: kAXButtonRole, check: check)
            return openButton.map { self.bool($0, kAXEnabledAttribute) == true } ?? false
        }
        let ready = try state()
        guard ready.goTo == nil, let openButton, bool(openButton, kAXEnabledAttribute) == true,
              let currentButton = try find(ready.panel, identifier: "OKButton", role: kAXButtonRole, check: check),
              CFEqual(currentButton, openButton) else { throw unsupported() }
        // 控件查询可能耗时；提交前重新核实原 modal 的焦点，不能沿用查询前的快照。
        guard try state().goTo == nil else { throw unsupported() }
        try effect(permit, check: check) { AXUIElementPerformAction(openButton, kAXPressAction as CFString) }
        try waitForFileDialog(check: check) {
            let current = try sheets(root())
            return !current.contains { self.desktop.identifier($0) == panelID }
        }
        // 只能确认原生对话框已完成选择，网页是否上传完成仍需要观察。
        completed = true
        return ["selected": true, "dialogClosed": true]
    }

    func effect(_ permit: ChromeInputPermit, check: () throws -> Void,
                unless satisfied: () -> Bool = { false }, _ operation: () -> AXError) throws {
        try check()
        let alreadySatisfied = satisfied()
        // AX 读取也可能跨过取消或截止点；跳过写入前仍需复核。
        try check()
        if alreadySatisfied { return }
        guard try cancellation.inputEffect(permit: permit, operation) == .success else {
            throw HelperFailure(code: "FILE_SELECTION_FAILED", message: "系统未完成文件选择操作，请检查对话框状态后重试")
        }
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value as? String : nil
    }

    private func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private func children(_ element: AXUIElement, required: Bool = false) throws -> [AXUIElement] {
        AXUIElementSetMessagingTimeout(element, 0.2)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        if !required && (error == .noValue || error == .attributeUnsupported) { return [] }
        guard error == .success, let nodes = value as? [AXUIElement] else {
            throw HelperFailure(code: "FILE_DIALOG_UNVERIFIED", message: "无法读取原生文件选择框结构")
        }
        return nodes
    }

    private func identity(_ element: AXUIElement) -> FileDialogIdentity {
        var pid: pid_t = 0
        _ = AXUIElementGetPid(element, &pid)
        return FileDialogIdentity(windowId: desktop.identifier(element) ?? 0, pid: pid,
                                  role: string(element, kAXRoleAttribute) ?? "", identifier: string(element, kAXIdentifierAttribute) ?? "")
    }

    private func find(_ root: AXUIElement, identifier: String, role: String, check: () throws -> Void) throws -> AXUIElement? {
        var queue = [root], index = 0
        while index < queue.count {
            try check()
            guard queue.count <= 512 else { throw unsupported() }
            let element = queue[index]; index += 1
            AXUIElementSetMessagingTimeout(element, 0.2)
            // 仅遍历已验证的原生 sheet，禁止进入网页可伪造的可访问性子树。
            if string(element, kAXRoleAttribute) == "AXWebArea" { continue }
            if string(element, kAXIdentifierAttribute) == identifier && string(element, kAXRoleAttribute) == role { return element }
            queue.append(contentsOf: try children(element))
        }
        return nil
    }

    private func unsupported() -> HelperFailure {
        HelperFailure(code: "FILE_DIALOG_UNSUPPORTED", message: "当前文件选择框结构不受支持，未继续发送输入")
    }
}
