import SwiftUI
import SafarierCore
import SafarierNetwork

/// 新建 / 编辑环境。字段与命令行 `profile create/update` 一致；模式创建后不能改（数据目录跟着 id 走）。
struct ProfileEditorView: View {
    enum OutboundKind: Hashable {
        case direct
        case proxy
        case node
    }

    /// 语言 / 时区从哪来。
    enum RegionSource: Hashable {
        /// 启动时按代理出口 IP 的国家自动匹配。
        case proxy
        case system
        case custom
    }

    @ObservedObject var model: ManagerModel
    let original: Profile?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var name: String
    @State private var mode: ProfileMode
    @State private var languageSource: RegionSource
    @State private var languages: String
    @State private var timeZoneSource: RegionSource
    @State private var timeZone: String
    @State private var startURL: String
    @State private var outboundKind: OutboundKind
    @State private var proxyID: UUID?
    @State private var subscriptionID: UUID?
    @State private var nodeName: String?
    @State private var showNodePicker = false
    @State private var deviceModel: String?
    @State private var spi: SPIFeatures
    @State private var notes: String
    @State private var allowsAgentAccess: Bool
    @State private var errorText: String?

    private var chromeBackground: Color {
        MetallicTheme.chromeBackground(for: colorScheme)
    }

    private var chromeOpacity: Double {
        MetallicTheme.chromeOpacity(for: colorScheme)
    }

    private var contentBackground: Color {
        colorScheme == .dark
            ? Color(red: 0x07 / 255.0, green: 0x0A / 255.0, blue: 0x10 / 255.0).opacity(0.95)
            : Color(red: 0xFA / 255.0, green: 0xFB / 255.0, blue: 0xFD / 255.0).opacity(0.95)
    }

    private var inputBackground: Color {
        Color.black.opacity(colorScheme == .dark ? 0.25 : 0.05)
    }

    private var inputBorderColor: Color {
        Color.white.opacity(colorScheme == .dark ? 0.12 : 0.18)
    }

    static let languagePresets: [(title: String, value: String)] = [
        ("英语（美国）", "en-US, en"),
        ("英语（英国）", "en-GB, en"),
        ("日语", "ja-JP, ja"),
        ("韩语", "ko-KR, ko"),
        ("泰语", "th-TH, th"),
        ("简体中文", "zh-CN, zh"),
        ("繁体中文（台湾）", "zh-TW, zh"),
        ("繁体中文（香港）", "zh-HK, zh"),
        ("德语", "de-DE, de"),
        ("法语", "fr-FR, fr"),
        ("西班牙语", "es-ES, es"),
    ]

    init(model: ManagerModel, original: Profile?) {
        self.model = model
        self.original = original
        _name = State(initialValue: original?.name ?? "")
        _mode = State(initialValue: original?.mode ?? .persistent)
        _languageSource = State(initialValue: original.map {
            $0.followProxyLanguages ? .proxy : $0.languages.isEmpty ? .system : .custom
        } ?? .system)
        _languages = State(initialValue: original?.languages.joined(separator: ", ") ?? "")
        _timeZoneSource = State(initialValue: original.map {
            $0.followProxyTimeZone ? .proxy : $0.timeZoneIdentifier == nil ? .system : .custom
        } ?? .system)
        _timeZone = State(initialValue: original?.timeZoneIdentifier ?? "")
        _startURL = State(initialValue: original?.startURL?.absoluteString ?? "")
        _outboundKind = State(initialValue: original?.subscriptionID != nil ? .node : original?.proxyID != nil ? .proxy : .direct)
        _proxyID = State(initialValue: original?.proxyID)
        _subscriptionID = State(initialValue: original?.subscriptionID)
        _nodeName = State(initialValue: original?.nodeName)
        _deviceModel = State(initialValue: original?.deviceModel)
        _spi = State(initialValue: original?.spi ?? Self.defaultSPI(for: .persistent))
        _notes = State(initialValue: original?.notes ?? "")
        _allowsAgentAccess = State(initialValue: original?.allowsAgentAccess ?? true)
    }

    private func inputContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(inputBorderColor, lineWidth: 0.8)
                    )
            )
    }

    var body: some View {
        ZStack {
            // 背景磨砂与深邃外壳
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
            contentBackground

            VStack(spacing: 0) {
                // 顶部横幅
                headerBar

                Divider().opacity(0.2)

                // 核心表单区域（卡片化滚动列表）
                ScrollView {
                    VStack(spacing: 16) {
                        basicInfoCard
                        networkCard
                        regionCard
                        deviceModelCard
                        privacyCard
                        otherParamsCard
                    }
                    .padding(20)
                }

                Divider().opacity(0.2)

                // 底部操作条
                bottomBar
            }
        }
        .frame(width: 640, height: 700)
        .onChange(of: [name, languages, timeZone, startURL]) { errorText = nil }
        .onChange(of: subscriptionID) {
            // 单节点订阅直接选中；多节点订阅保留仍然有效的原选择。
            if let nodes = selectedSubscription?.nodes, nodes.count == 1 {
                nodeName = nodes[0].name
            } else if let nodeName, selectedSubscription?.nodes.contains(where: { $0.name == nodeName }) != true {
                self.nodeName = nil
            }
            errorText = nil
        }
        .onChange(of: outboundKind) {
            errorText = nil
            // 新环境：选了代理或节点就默认跟随代理出口，改回直连就回到跟随系统（自定义的不动）。
            guard original == nil else { return }
            let follow = outboundKind != .direct
            if follow ? languageSource == .system : languageSource == .proxy { languageSource = follow ? .proxy : .system }
            if follow ? timeZoneSource == .system : timeZoneSource == .proxy { timeZoneSource = follow ? .proxy : .system }
        }
        .onChange(of: [languageSource, timeZoneSource]) { errorText = nil }
        .onChange(of: mode) {
            if original == nil { spi = Self.defaultSPI(for: mode) }
        }
        .onChange(of: deviceModel) {
            // 选了机型就一起打开高级隐私保护，网页里的 screen 尺寸才会跟着模拟的视口走（可以再手动关掉）。
            if deviceModel != nil { spi.insert(.fingerprintingProtections) }
        }
    }

    // MARK: - 顶部横幅
    private var headerBar: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(MetallicTheme.prominentGradient)
                    .frame(width: 42, height: 42)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(MetallicTheme.chromeBorder(for: colorScheme), lineWidth: 0.8)
                    )
                Image(systemName: original == nil ? "plus.rectangle.on.rectangle" : "pencil")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MetallicTheme.darkText)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(original == nil ? "新建环境" : "编辑环境「\(original?.name ?? "")」")
                    .font(.system(size: 16, weight: .bold))
                Text("配置独立数据沙盒、代理网络与系统指纹")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            chromeBackground.opacity(chromeOpacity)
        )
    }

    // MARK: - 基础信息
    private var basicInfoCard: some View {
        LiquidGlassCard(title: "基础信息", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("环境名称")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    inputContainer {
                        TextField("例如：美国-跨境", text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("允许 Agent 使用")
                            .font(.system(size: 13, weight: .medium))
                        Text("允许本地或远程 AI 智能体通过自动化端口调度此环境")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $allowsAgentAccess)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Divider().opacity(0.15)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("沙盒模式")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if original != nil {
                            Text("模式创建后不可更改")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Picker("沙盒模式", selection: $mode) {
                        Text("持久沙盒").tag(ProfileMode.persistent)
                        Text("临时沙盒").tag(ProfileMode.ephemeral)
                    }
                    .pickerStyle(.segmented)
                    .disabled(original != nil)

                    Text(DisplayText.modeDetail(mode) + (original == nil ? "。" : "。模式创建后不可更改。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 网络代理
    private var networkCard: some View {
        LiquidGlassCard(title: "网络代理", systemImage: "network") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("出站模式")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("出站模式", selection: $outboundKind) {
                        Text("直连出站").tag(OutboundKind.direct)
                        Text("独立代理").tag(OutboundKind.proxy)
                        Text("订阅节点").tag(OutboundKind.node)
                    }
                    .pickerStyle(.segmented)
                }

                switch outboundKind {
                case .direct:
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(MetallicTheme.accent)
                        Text("通过本地网络直接访问，不经过任何代理服务器。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    )

                case .proxy:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("代理配置")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $proxyID) {
                            Text("请选择代理").tag(UUID?.none)
                            ForEach(model.proxies) { proxy in
                                Text(verbatim: "\(proxy.name) — \(DisplayText.proxyKind(proxy.kind)) \(proxy.host):\(proxy.port)")
                                    .tag(UUID?.some(proxy.id))
                            }
                            if let proxyID, !model.proxies.contains(where: { $0.id == proxyID }) {
                                Text("已被删除的代理（\(proxyID.uuidString.prefix(8))）").tag(UUID?.some(proxyID))
                            }
                        }
                        .labelsHidden()

                        Text(outboundFooter)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .node:
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("所属订阅")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Picker("", selection: $subscriptionID) {
                                Text("请选择订阅").tag(UUID?.none)
                                ForEach(model.subscriptions) { subscription in
                                    Text(verbatim: "\(subscription.name)（\(subscription.nodes.count) 个节点）")
                                        .tag(UUID?.some(subscription.id))
                                }
                            }
                            .labelsHidden()
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("节点选择")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Button { showNodePicker = true } label: {
                                HStack(spacing: 8) {
                                    if let node = selectedNode {
                                        Text(node.name).lineLimit(1)
                                        ProtocolBadge(type: node.type)
                                    } else {
                                        Text(nodeName.map { "「\($0)」已不在订阅里" } ?? "选择节点…")
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(inputBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(inputBorderColor, lineWidth: 0.8)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(selectedSubscription == nil)
                            .popover(isPresented: $showNodePicker, arrowEdge: .trailing) {
                                NodePickerView(nodes: selectedSubscription?.nodes ?? [], selection: nodeName, nodeSpeeds: model.nodeSpeeds) { name in
                                    nodeName = name
                                    showNodePicker = false
                                }
                            }
                        }

                        Text(outboundFooter)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 语言与时区
    private var regionCard: some View {
        LiquidGlassCard(title: "语言与时区", systemImage: "globe") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("语言来源")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    regionSourcePicker("语言来源", selection: $languageSource)
                        .labelsHidden()

                    if languageSource == .custom {
                        HStack(spacing: 6) {
                            inputContainer {
                                TextField("例如 en-US, en", text: $languages)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13))
                            }

                            Menu {
                                ForEach(Self.languagePresets, id: \.value) { preset in
                                    Button("\(preset.title)  \(preset.value)") { languages = preset.value }
                                }
                            } label: {
                                Image(systemName: "character.bubble")
                                    .frame(width: 28, height: 28)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("常用语言预设")
                        }
                    }
                }

                Divider().opacity(0.15)

                VStack(alignment: .leading, spacing: 8) {
                    Text("时区来源")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    regionSourcePicker("时区来源", selection: $timeZoneSource)
                        .labelsHidden()

                    if timeZoneSource == .custom {
                        HStack(spacing: 6) {
                            inputContainer {
                                TextField("例如 America/Los_Angeles", text: $timeZone)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13, design: .monospaced))
                            }

                            TimeZoneMenu(selection: $timeZone)
                        }
                    }

                    Text(regionFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Mac 机型模拟
    private var deviceModelCard: some View {
        LiquidGlassCard(title: "Mac 机型模拟", systemImage: "laptopcomputer") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("模拟机型")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $deviceModel) {
                        Text("跟随本机硬件").tag(String?.none)
                        ForEach(MacDeviceModel.categories, id: \.self) { category in
                            Section(category) {
                                ForEach(MacDeviceModel.presets.filter { $0.category == category }) { preset in
                                    Text(preset.name).tag(String?.some(preset.id))
                                }
                            }
                        }
                    }
                    .labelsHidden()
                }

                if let preset = deviceModel.flatMap(MacDeviceModel.preset) {
                    VStack(spacing: 6) {
                        specRow(title: "芯片规格", value: DisplayText.hardware(preset))
                        specRow(title: "屏幕色彩", value: DisplayText.screen(preset))
                        specRow(title: "网页探测值", value: DisplayText.webVisible(preset))
                        specRow(title: "推荐视口", value: DisplayText.viewport(preset))
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    )
                }

                Text(DisplayText.deviceModelNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func specRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Safari 原生隐私保护
    private var privacyCard: some View {
        LiquidGlassCard(title: "Safari 原生隐私保护", systemImage: "lock.shield") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(SPIFeatures.tokens, id: \.name) { token in
                    let text = DisplayText.spi(token.feature)
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(text.title)
                                .font(.system(size: 13, weight: .medium))
                            if !text.detail.isEmpty {
                                Text(text.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 12)
                        Toggle("", isOn: binding(for: token.feature))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    if token.name != SPIFeatures.tokens.last?.name {
                        Divider().opacity(0.15)
                    }
                }

                Text("直接启用 Safari 原生内核保护机制，零脚本篡改，默认推荐开启防护项。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 其他参数
    private var otherParamsCard: some View {
        LiquidGlassCard(title: "其他参数", systemImage: "ellipsis.circle") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("起始网址")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    inputContainer {
                        TextField("https://example.com", text: $startURL)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("环境备注")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    inputContainer {
                        TextField("可选备注信息", text: $notes, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .lineLimit(2...4)
                    }
                }
            }
        }
    }

    // MARK: - 底部操作条
    private var bottomBar: some View {
        HStack(spacing: 12) {
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(2)
            } else if let original, model.runState(original.id) != .stopped {
                Label("环境正在运行，配置将在下次启动时生效", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button("取消", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)

            LiquidGlassButton(
                title: original == nil ? "创建环境" : "保存修改",
                systemImage: original == nil ? "plus" : "checkmark",
                variant: .prominent,
                size: .regular
            ) {
                save()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            chromeBackground.opacity(chromeOpacity)
        )
    }

    private var selectedSubscription: Subscription? {
        subscriptionID.flatMap(model.subscription)
    }

    private var selectedNode: SubscriptionNode? {
        guard let nodeName else { return nil }
        return selectedSubscription?.nodes.first { $0.name == nodeName }
    }

    private var outboundFooter: String {
        switch outboundKind {
        case .direct: return "不经过代理。"
        case .proxy: return "代理用命令行 safarier proxy add 添加。代理只在启动时生效，换代理要重启这个环境。"
        case .node: return "启动时为这个环境单独起一个 sing-box，把节点转成本地 SOCKS5 交给 WebKit；节点连不上时页面加载失败，不会退回直连。节点按名字匹配，订阅刷新后仍然有效。"
        }
    }

    private var regionFooter: String {
        guard languageSource == .proxy || timeZoneSource == .proxy else {
            return "跟随系统时使用宿主机的语言和时区。"
        }
        return "跟随代理：每次启动经代理查询出口 IP 所在国家，自动设置语言和时区（时区跟随时一并开启引擎层时区同步）；查询失败时按节点名称推断，仍无法判断则跟随系统。"
    }

    /// 选了「自定义」却没填：报错，不悄悄存成「跟随系统」。
    static func customRegionError(languageSource: RegionSource, languages: String, timeZoneSource: RegionSource, timeZone: String) -> String? {
        if languageSource == .custom, !languages.split(separator: ",").contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "请填写语言标签（例如 en-US, en），或改选「跟随系统」。"
        }
        if timeZoneSource == .custom, timeZone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请填写时区（例如 America/Los_Angeles），或改选「跟随系统」。"
        }
        return nil
    }

    private func regionSourcePicker(_ title: String, selection: Binding<RegionSource>) -> some View {
        Picker(title, selection: selection) {
            Text(DisplayText.followProxy).tag(RegionSource.proxy)
            Text("跟随系统").tag(RegionSource.system)
            Text("自定义").tag(RegionSource.custom)
        }
    }

    /// 新环境默认开启全部原生隐私保护（WebRTC 和 WebGPU 除外），持久和临时环境一样。
    static func defaultSPI(for mode: ProfileMode) -> SPIFeatures {
        .defaultFeatures
    }

    private func binding(for feature: SPIFeatures) -> Binding<Bool> {
        Binding(
            get: { spi.contains(feature) },
            set: { enabled in
                if enabled { spi.insert(feature) } else { spi.remove(feature) }
            }
        )
    }

    private func save() {
        errorText = nil
        var url: URL?
        let rawURL = startURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawURL.isEmpty {
            // 和浏览窗口的地址栏一样：没写 scheme 时补 https://。
            url = rawURL.contains("://") ? URL(string: rawURL) : URL(string: "https://" + rawURL)
            guard url != nil else {
                errorText = "起始网址不合法：\(rawURL)"
                return
            }
        }

        if outboundKind == .direct, languageSource == .proxy || timeZoneSource == .proxy {
            errorText = "「跟随代理」需要选择独立代理或订阅节点。"
            return
        }
        if let message = Self.customRegionError(languageSource: languageSource, languages: languages, timeZoneSource: timeZoneSource, timeZone: timeZone) {
            errorText = message
            return
        }

        var profile = original ?? Profile(name: name, mode: mode)
        profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.followProxyLanguages = languageSource == .proxy
        profile.languages = languageSource != .custom ? [] : languages.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        profile.followProxyTimeZone = timeZoneSource == .proxy
        let zone = timeZone.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.timeZoneIdentifier = timeZoneSource != .custom || zone.isEmpty ? nil : zone
        profile.startURL = url
        switch outboundKind {
        case .direct:
            profile.proxyID = nil
            profile.subscriptionID = nil
            profile.nodeName = nil
        case .proxy:
            guard proxyID != nil else {
                errorText = "请选择代理。"
                return
            }
            profile.proxyID = proxyID
            profile.subscriptionID = nil
            profile.nodeName = nil
        case .node:
            guard subscriptionID != nil, nodeName != nil else {
                errorText = "请选择订阅和节点。"
                return
            }
            profile.proxyID = nil
            profile.subscriptionID = subscriptionID
            profile.nodeName = nodeName
        }
        profile.deviceModel = deviceModel
        profile.spi = spi
        profile.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.allowsAgentAccess = allowsAgentAccess

        do {
            try model.save(profile, isNew: original == nil)
            dismiss()
        } catch {
            errorText = DisplayText.describe(error)
        }
    }
}

/// 常用时区 + 按地区分组的完整列表。
struct TimeZoneMenu: View {
    @Binding var selection: String

    private static let common = [
        "America/Los_Angeles", "America/Denver", "America/Chicago", "America/New_York",
        "Europe/London", "Europe/Paris", "Europe/Berlin",
        "Asia/Tokyo", "Asia/Seoul", "Asia/Bangkok", "Asia/Singapore", "Asia/Hong_Kong", "Asia/Taipei", "Asia/Shanghai",
        "Australia/Sydney",
    ]

    private static let regions: [(name: String, zones: [String])] = Dictionary(
        grouping: TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") },
        by: { String($0.prefix { $0 != "/" }) }
    )
    .map { (name: $0.key, zones: $0.value.sorted()) }
    .sorted { $0.name < $1.name }

    var body: some View {
        Menu {
            Section("常用") {
                ForEach(Self.common, id: \.self) { zone in
                    Button(DisplayText.timeZone(zone)) { selection = zone }
                }
            }
            Divider()
            ForEach(Self.regions, id: \.name) { region in
                Menu(region.name) {
                    ForEach(region.zones, id: \.self) { zone in
                        Button(zone) { selection = zone }
                    }
                }
            }
        } label: {
            Image(systemName: "globe")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("选择时区")
    }
}

/// 订阅节点选择：按名称或服务器搜索。
struct NodePickerView: View {
    let nodes: [SubscriptionNode]
    let selection: String?
    var nodeSpeeds: [UUID: NodeSpeedResult] = [:]
    let onSelect: (String) -> Void

    @State private var query = ""

    private var filtered: [SubscriptionNode] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nodes }
        return nodes.filter {
            $0.name.localizedCaseInsensitiveContains(text) || "\($0.server):\($0.serverPort)".contains(text)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索名称或服务器", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            List(filtered) { node in
                Button { onSelect(node.name) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .opacity(node.name == selection ? 1 : 0)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.name).lineLimit(1)
                            Text(verbatim: "\(node.server):\(node.serverPort)")
                                .font(.caption)
                                .monospaced()
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if let speed = nodeSpeeds[node.id], case .success(let ms) = speed {
                            Text("\(ms) ms")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(ms < 200 ? Color.green : (ms < 500 ? Color.orange : Color.red))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(
                                    Capsule()
                                        .fill((ms < 200 ? Color.green : (ms < 500 ? Color.orange : Color.red)).opacity(0.12))
                                )
                        }
                        ProtocolBadge(type: node.type)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            Divider()
            Text(query.isEmpty ? "共 \(nodes.count) 个节点" : "\(filtered.count) / \(nodes.count) 个节点")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .frame(width: 400, height: 440)
    }
}
