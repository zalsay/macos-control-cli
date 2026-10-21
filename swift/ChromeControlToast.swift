import AppKit

struct ChromeToastScreen {
    let frame: CGRect
    let visibleFrame: CGRect
}

func chromeToastFrame(window: WindowBounds, screens: [ChromeToastScreen]) -> CGRect? {
    guard let primary = screens.first else { return nil }
    // CG 使用主屏左上原点，AppKit 使用主屏左下原点；全程使用逻辑点而非 Retina 像素。
    let rect = CGRect(x: window.x, y: primary.frame.maxY - window.y - window.height,
                      width: window.width, height: window.height)
    let intersections = screens.map { screen -> (ChromeToastScreen, CGFloat) in
        let overlap = screen.frame.intersection(rect)
        return (screen, overlap.isNull ? 0 : overlap.width * overlap.height)
    }
    guard let (screen, area) = intersections.max(by: { $0.1 < $1.1 }), area > 0 else { return nil }
    let visible = screen.visibleFrame
    let width = min(560, visible.width - 32)
    let height: CGFloat = 80
    let safeMargin: CGFloat = 80
    guard width > 0, visible.height >= height + safeMargin * 2 else { return nil }
    return CGRect(x: visible.midX - width / 2, y: visible.maxY - safeMargin - height,
                  width: width, height: height)
}

func shouldPauseChromeForPointer(sourcePID: Int64?, helperPID: pid_t, insideControls: Bool) -> Bool {
    !insideControls && sourcePID != Int64(helperPID)
}

func chromeToastFrameAvoidingPointer(frame: CGRect, screenPoint: CGPoint, screens: [ChromeToastScreen]) -> CGRect {
    guard let primary = screens.first else { return frame }
    let point = CGPoint(x: screenPoint.x, y: primary.frame.maxY - screenPoint.y)
    guard frame.contains(point), let screen = screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) else {
        return frame
    }
    var moved = frame
    moved.origin.y = frame.midY > screen.visibleFrame.midY
        ? screen.visibleFrame.minY + 80
        : screen.visibleFrame.maxY - frame.height - 80
    // 无法同时留出上下安全边距时保留控制条，交给完整指针 guard 拒绝输入。
    guard moved.minY >= screen.visibleFrame.minY + 80,
          moved.maxY <= screen.visibleFrame.maxY - 80,
          !moved.contains(point) else { return frame }
    return moved
}

private final class ChromeToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ChromeToastButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
}

// 所有 UI 与观察器回调都在主线程处理；只监听鼠标，不申请键盘 Input Monitoring。
final class ChromeControlToast: NSObject {
    private struct Execution {
        let lease: UInt64
        let generation: UInt64
        let target: TargetWindow
        var title: String
        let cancellation: InputCancellation
    }

    private var panel: ChromeToastPanel?
    private var execution: Execution?
    private var activationObserver: NSObjectProtocol?
    private var pointerMonitor: Any?
    private var countdownTimer: Timer?
    private let desktopMode: Bool
    private let logoURL: URL
    private let stateLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let executeButton = ChromeToastButton(title: "继续", target: nil, action: nil)
    private let pauseButton = ChromeToastButton(title: "暂停", target: nil, action: nil)

    init(logoURL: URL? = nil, desktopMode: Bool = false) {
        self.desktopMode = desktopMode
        self.logoURL = logoURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("assets/copis-logo.png")
        super.init()
    }

    func show(over window: WindowBounds, target: TargetWindow, title: String = "",
              cancellation: InputCancellation, generation: UInt64) throws {
        let lease = try cancellation.beginExecution(generation: generation)
        let isNewExecution = execution?.lease != lease || execution?.cancellation !== cancellation
        if isNewExecution { stopWatching() }
        execution = Execution(lease: lease, generation: generation, target: target,
                              title: title.isEmpty ? (desktopMode ? "当前应用窗口" : "当前Chrome页面") : title, cancellation: cancellation)
        if isNewExecution {
            guard cancellation.onExecutionEnd(lease: lease, handler: { [weak self, weak cancellation] in
                DispatchQueue.main.async { [weak self, weak cancellation] in
                    guard let self, let cancellation, self.isCurrent(lease: lease, cancellation: cancellation) else { return }
                    self.dismiss()
                }
            }) else {
                dismiss()
                throw HelperFailure.cancelled
            }
            watchExecution(lease: lease, cancellation: cancellation)
        }
        let screens = NSScreen.screens.map { ChromeToastScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        guard let frame = chromeToastFrame(window: window, screens: screens) else {
            throw HelperFailure(code: "FOCUS_UNVERIFIED", message: "无法在目标屏幕显示接管倒计时，未发送输入")
        }
        if panel == nil { panel = makePanel() }
        try cancellation.effect(generation: generation) { panel?.setFrame(frame, display: false) }
        panel?.contentView?.layoutSubtreeIfNeeded()
        refresh(lease: lease)
        // 先展示控制条再开始计时，不能把 UI 创建时间计入用户的三秒准备时间。
        cancellation.startCountdown(lease: lease)
        try cancellation.check(generation)
    }

    private func refresh(lease: UInt64) {
        guard let execution, execution.lease == lease else { return }
        guard let state = execution.cancellation.executionState(lease: lease) else { dismiss(); return }
        updateLabels(state: state, execution: execution)
        switch state {
        case .countdown:
            executeButton.isEnabled = false
            pauseButton.title = "取消"
            pauseButton.isEnabled = true
            if countdownTimer == nil {
                let epoch = execution.cancellation.inputSnapshot()
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self, weak cancellation = execution.cancellation] _ in
                    guard let self, let cancellation, self.isCurrent(lease: lease, cancellation: cancellation),
                          cancellation.inputSnapshot() == epoch else { return }
                    self.refresh(lease: lease)
                }
                countdownTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        case .paused:
            stopCountdownTimer()
            executeButton.isEnabled = true
            pauseButton.title = "暂停"
            pauseButton.isEnabled = false
        case .running:
            stopCountdownTimer()
            executeButton.isEnabled = false
            pauseButton.title = "暂停"
            pauseButton.isEnabled = true
        }
        do {
            try execution.cancellation.effect(generation: execution.generation) { panel?.orderFrontRegardless() }
        } catch { dismiss() }
    }

    private func updateLabels(state: ChromeExecutionState, execution: Execution) {
        let page = "「\(execution.title)」\(desktopMode ? "窗口" : "页面")"
        switch state {
        case .countdown(let seconds):
            stateLabel.stringValue = "AI即将接管\(page)"
            detailLabel.stringValue = "\(seconds)秒后接管 · 请松开鼠标"
        case .running:
            stateLabel.stringValue = "AI正在操作\(page)"
            detailLabel.stringValue = "您可以随时暂停并接管"
        case .paused:
            stateLabel.stringValue = "AI已暂停\(page)"
            detailLabel.stringValue = "点击继续后将重新倒计时 3 秒"
        }
    }

    private func stopCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    @objc private func executeClicked(_ sender: NSButton) {
        guard let execution else { return }
        _ = execution.cancellation.resumeExecution(lease: execution.lease)
        refresh(lease: execution.lease)
    }

    @objc private func pauseClicked(_ sender: NSButton) {
        guard let execution else { return }
        _ = execution.cancellation.pauseExecution(lease: execution.lease)
        refresh(lease: execution.lease)
    }

    @objc private func closeClicked(_ sender: NSButton) {
        guard let execution else { return }
        _ = execution.cancellation.pauseExecution(lease: execution.lease)
        dismiss()
    }

    func updateTitle(target: TargetWindow, title: String, cancellation: InputCancellation, generation: UInt64) {
        guard var current = execution,
              current.target.windowId == target.windowId, current.target.pid == target.pid,
              current.generation == generation, current.cancellation === cancellation,
              cancellation.snapshot() == generation, panel?.isVisible == true,
              let state = cancellation.executionState(lease: current.lease) else { return }
        current.title = title.isEmpty ? (desktopMode ? "当前应用窗口" : "当前Chrome页面") : title
        execution = current
        updateLabels(state: state, execution: current)
    }

    private func isCurrent(lease: UInt64, cancellation: InputCancellation) -> Bool {
        execution?.lease == lease && execution?.cancellation === cancellation
    }

    private func watchExecution(lease: UInt64, cancellation: InputCancellation) {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self, weak cancellation] notification in
            // 先保存已观察到的激活身份和送达时间；不能在 core 提交锁内同步取锁。
            guard let timestamp = cancellation?.eventTimestamp() else { return }
            let activatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            DispatchQueue.main.async { [weak self, weak cancellation] in
                guard let self, let cancellation, self.isCurrent(lease: lease, cancellation: cancellation),
                      let execution = self.execution else { return }
                // 已知外部激活不能被随后切回 Chrome 吞掉；缺失身份时才回读当前前台。
                let foregroundPID = activatedPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard foregroundPID != execution.target.pid,
                      cancellation.pauseForUserInteraction(lease: lease, timestamp: timestamp) else { return }
                self.refresh(lease: lease)
            }
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                           .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                           .leftMouseUp, .rightMouseUp, .otherMouseUp, .scrollWheel]
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self, weak cancellation] event in
            guard let self, let cancellation, self.isCurrent(lease: lease, cancellation: cancellation) else { return }
            let cgEvent = event.cgEvent
            let sourcePID = cgEvent.map { $0.getIntegerValueField(.eventSourceUnixProcessID) }
            let location: CGPoint
            if let cgEvent, let primary = NSScreen.screens.first {
                location = CGPoint(x: cgEvent.location.x, y: primary.frame.maxY - cgEvent.location.y)
            } else {
                location = NSEvent.mouseLocation
            }
            let insideControls = self.panel.map { $0.isVisible && $0.frame.contains(location) } ?? false
            guard shouldPauseChromeForPointer(sourcePID: sourcePID, helperPID: ProcessInfo.processInfo.processIdentifier,
                                              insideControls: insideControls),
                  cancellation.pauseForUserInteraction(lease: lease, timestamp: event.timestamp) else { return }
            self.refresh(lease: lease)
        }
    }

    private func stopWatching() {
        stopCountdownTimer()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
    }

    func dismiss() {
        stopWatching()
        execution = nil
        panel?.orderOut(nil)
    }

    deinit { stopWatching() }

    func avoidPointer(_ screenPoint: CGPoint) {
        guard let execution, execution.cancellation.executionPaused(lease: execution.lease) != nil,
              let panel, panel.isVisible else { return }
        let screens = NSScreen.screens.map { ChromeToastScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let moved = chromeToastFrameAvoidingPointer(frame: panel.frame, screenPoint: screenPoint, screens: screens)
        if moved != panel.frame {
            do {
                try execution.cancellation.effect(generation: execution.generation) { panel.setFrame(moved, display: true) }
            } catch { dismiss() }
        }
    }

    private func makePanel() -> ChromeToastPanel {
        let toast = ChromeToastPanel(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        toast.title = desktopMode ? "AI正在操作应用窗口..." : "AI正在操作Chrome窗口..."
        toast.titleVisibility = .hidden
        toast.titlebarAppearsTransparent = true
        toast.isMovable = false
        toast.isReleasedWhenClosed = false
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.hasShadow = true
        toast.ignoresMouseEvents = false
        toast.hidesOnDeactivate = false
        toast.level = .statusBar
        toast.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        toast.animationBehavior = .none

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .vibrantDark)
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        toast.contentView = background

        let icon = NSImageView(image: NSImage(contentsOf: logoURL) ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityIdentifier("copis-chrome-toast-logo")
        for (label, identifier, size, weight) in [
            (stateLabel, "copis-chrome-toast-primary", CGFloat(16), NSFont.Weight.medium),
            (detailLabel, "copis-chrome-toast-secondary", CGFloat(12), NSFont.Weight.regular),
        ] {
            label.setAccessibilityIdentifier(identifier)
            label.font = .systemFont(ofSize: size, weight: weight)
            label.textColor = .labelColor
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        executeButton.target = self
        executeButton.action = #selector(executeClicked(_:))
        executeButton.setAccessibilityIdentifier("copis-chrome-execute")
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked(_:))
        pauseButton.setAccessibilityIdentifier("copis-chrome-pause")
        // 复用系统标题栏按钮；只接管红色关闭的动作，黄/绿保持非最小化、非缩放窗口的禁用态。
        if let closeButton = toast.standardWindowButton(.closeButton) {
            closeButton.target = self
            closeButton.action = #selector(closeClicked(_:))
            closeButton.setAccessibilityIdentifier("copis-chrome-close")
            closeButton.setAccessibilityLabel(desktopMode ? "关闭应用控制条" : "关闭Copis Chrome控制条")
        }
        for button in [executeButton, pauseButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 12, weight: .medium)
        }
        for view in [icon, stateLabel, detailLabel, executeButton, pauseButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 36), icon.heightAnchor.constraint(equalToConstant: 36),
            icon.centerYAnchor.constraint(equalTo: background.centerYAnchor, constant: 12),
            stateLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            stateLabel.trailingAnchor.constraint(equalTo: executeButton.leadingAnchor, constant: -10),
            stateLabel.centerYAnchor.constraint(equalTo: background.centerYAnchor, constant: 4),
            detailLabel.leadingAnchor.constraint(equalTo: stateLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: stateLabel.trailingAnchor),
            detailLabel.centerYAnchor.constraint(equalTo: background.centerYAnchor, constant: 24),
            executeButton.widthAnchor.constraint(equalToConstant: 52), executeButton.heightAnchor.constraint(equalToConstant: 28),
            executeButton.centerYAnchor.constraint(equalTo: background.centerYAnchor, constant: 12),
            pauseButton.leadingAnchor.constraint(equalTo: executeButton.trailingAnchor, constant: 8),
            pauseButton.widthAnchor.constraint(equalToConstant: 52), pauseButton.heightAnchor.constraint(equalToConstant: 28),
            pauseButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            pauseButton.centerYAnchor.constraint(equalTo: executeButton.centerYAnchor),
        ])
        return toast
    }
}
