import SwiftUI
import SafarierCore
import SafarierNetwork

/// 选中订阅时的详情面板：顶部 Liquid Glass 操作横幅 + 节点搜索与映射表。
struct SubscriptionDetailView: View {
    @ObservedObject var model: ManagerModel
    let subscription: Subscription
    @State private var query = ""
    @State private var copiedFeedback = false

    private var filteredNodes: [SubscriptionNode] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return subscription.nodes }
        return subscription.nodes.filter {
            $0.name.localizedCaseInsensitiveContains(text) ||
            $0.server.localizedCaseInsensitiveContains(text) ||
            "\($0.serverPort)".contains(text) ||
            $0.type.rawValue.localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        let refreshing = model.refreshing.contains(subscription.id)
        let usage = Dictionary(grouping: model.profiles(using: subscription), by: { $0.nodeName ?? "" })

        VStack(alignment: .leading, spacing: 0) {
            header(refreshing)
                .padding(20)

            Divider().opacity(0.3)

            // 搜索过滤栏
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("搜索节点…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    LiquidGlassBackground(radius: 10, interactive: false, showsSheen: false)
                )

                Spacer()

                HStack(spacing: 8) {
                    let testedCount = subscription.nodes.filter { model.nodeSpeeds[$0.id] != nil }.count
                    if testedCount > 0 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(MetallicTheme.accent)
                                .frame(width: 5, height: 5)
                            Text("已测速 \(testedCount) / \(subscription.nodes.count)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(MetallicTheme.accent)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(MetallicTheme.accent.opacity(0.12))
                                .overlay(Capsule().stroke(MetallicTheme.accent.opacity(0.28), lineWidth: 0.5))
                        )
                    }

                    Text(query.isEmpty ? "共 \(subscription.nodes.count) 个节点" : "匹配 \(filteredNodes.count) / \(subscription.nodes.count) 个节点")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider().opacity(0.3)

            if subscription.nodes.isEmpty {
                ContentUnavailableView(
                    "暂无节点",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("未获取到节点，可点击「刷新订阅」重新解析。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredNodes.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filteredNodes) {
                    TableColumn("节点名称", value: \.name)
                        .width(min: 140, ideal: 200)

                    TableColumn("协议") { node in
                        ProtocolBadge(type: node.type)
                    }
                    .width(min: 65, ideal: 75, max: 90)

                    TableColumn("服务器与端口") { node in
                        Text(verbatim: "\(node.server):\(node.serverPort)")
                            .font(.system(size: 11.5, design: .monospaced))
                    }
                    .width(min: 140, ideal: 180)

                    TableColumn("传输层") { node in
                        Text(node.transport ?? "tcp")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 55, ideal: 65, max: 80)

                    TableColumn("TLS") { node in
                        if node.tls {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.green)
                                .font(.system(size: 11))
                                .help(node.serverName ?? "TLS 加密")
                        } else {
                            Text("—")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .width(min: 40, ideal: 45, max: 55)

                    TableColumn("延迟 / 测速") { node in
                        NodeLatencyCell(
                            result: model.nodeSpeeds[node.id],
                            isTesting: model.testingNodeIDs.contains(node.id),
                            onTest: { model.testSpeed(node: node) }
                        )
                    }
                    .width(min: 110, ideal: 130, max: 155)

                    TableColumn("绑定环境") { node in
                        if let profiles = usage[node.name], !profiles.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(profiles) { profile in
                                    Text(profile.name)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule()
                                                .fill(MetallicTheme.accent.opacity(0.14))
                                                .overlay(Capsule().stroke(MetallicTheme.accent.opacity(0.3), lineWidth: 0.5))
                                        )
                                        .foregroundStyle(MetallicTheme.accent)
                                }
                            }
                        } else {
                            Text("未绑定")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .width(min: 80, ideal: 140)
                }
            }
        }
    }

    private func header(_ refreshing: Bool) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(MetallicTheme.darkText)
                .frame(width: 56, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(MetallicTheme.prominentGradient)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(MetallicTheme.metallicRimBorder, lineWidth: 1.0)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(subscription.name)
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(1)

                    Text("\(subscription.nodes.count) 节点")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.06))
                                .overlay(Capsule().stroke(Color.white.opacity(0.24), lineWidth: 0.5))
                        )
                }

                HStack(spacing: 6) {
                    let isInline = model.isInline(subscription)
                    Text(isInline ? "本地自定义节点" : subscription.url.absoluteString)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !isInline {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(subscription.url.absoluteString, forType: .string)
                            copiedFeedback = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedFeedback = false }
                        } label: {
                            Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundStyle(copiedFeedback ? .green : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("拷贝订阅链接")
                    }
                }

                HStack(spacing: 8) {
                    ForEach(protocolCounts, id: \.type) { item in
                        HStack(spacing: 3) {
                            ProtocolBadge(type: item.type)
                            Text("\(item.count)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    Text(updatedText)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 8) {
                let isBatchTesting = model.batchTestingSubscriptionIDs.contains(subscription.id)
                HStack(spacing: 8) {
                    if isBatchTesting {
                        LiquidGlassButton(
                            title: "停止测速",
                            systemImage: "stop.fill",
                            variant: .destructive,
                            size: .regular
                        ) {
                            model.cancelBatchSpeedTest(subscriptionID: subscription.id)
                        }
                    } else {
                        LiquidGlassButton(
                            title: "一键测速",
                            systemImage: "bolt.fill",
                            variant: .regular,
                            size: .regular
                        ) {
                            model.testAllSpeed(subscription: subscription)
                        }
                        .disabled(subscription.nodes.isEmpty || refreshing)
                    }

                    LiquidGlassButton(
                        title: refreshing ? "正在拉取…" : "刷新订阅",
                        systemImage: refreshing ? nil : "arrow.clockwise",
                        variant: .prominent,
                        size: .regular
                    ) {
                        model.refresh(subscription)
                    }
                    .disabled(refreshing || isBatchTesting)
                }

                Button(role: .destructive) {
                    model.confirmation = .deleteSubscription(subscription)
                } label: {
                    Label("删除订阅…", systemImage: "trash")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .disabled(refreshing || isBatchTesting)
            }
        }
        .padding(20)
        .background(
            LiquidGlassBackground(radius: 18, interactive: true, showsSheen: true)
        )
    }

    private var protocolCounts: [(type: SubscriptionNodeType, count: Int)] {
        SubscriptionNodeType.allCases.compactMap { type in
            let count = subscription.nodes.filter { $0.type == type }.count
            return count == 0 ? nil : (type, count)
        }
    }

    private var updatedText: String {
        guard let updatedAt = subscription.updatedAt else { return "· 从未拉取" }
        return "· 更新于 " + updatedAt.formatted(.relative(presentation: .named))
    }
}

// MARK: - 添加订阅表单

/// 添加订阅：与命令行 `sub add` 一样，先拉取（或解析粘贴的节点链接）成功再保存。
struct SubscriptionEditorView: View {
    @ObservedObject var model: ManagerModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var name = ""
    @State private var url = ""
    @State private var busy = false
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

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
            contentBackground

            VStack(spacing: 0) {
                // 头部
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(MetallicTheme.prominentGradient)
                            .frame(width: 42, height: 42)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(MetallicTheme.chromeBorder(for: colorScheme), lineWidth: 0.8)
                            )
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(MetallicTheme.darkText)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("添加节点订阅")
                            .font(.system(size: 16, weight: .bold))
                        Text("支持通用订阅链接或直接粘贴节点")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(chromeBackground.opacity(chromeOpacity))

                Divider().opacity(0.2)

                // 表单主体
                ScrollView {
                    VStack(spacing: 16) {
                        LiquidGlassCard(title: "订阅参数", systemImage: "antenna.radiowaves.left.and.right") {
                            VStack(alignment: .leading, spacing: 14) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("订阅名称")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    TextField("例如：主力节点", text: $name)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13))
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

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("订阅链接或节点内容")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    TextEditor(text: $url)
                                        .font(.system(size: 12, design: .monospaced))
                                        .frame(height: 110)
                                        .padding(8)
                                        .background(inputBackground)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(inputBorderColor, lineWidth: 0.8)
                                        )
                                }

                                HStack(spacing: 8) {
                                    Image(systemName: "info.circle")
                                        .font(.caption)
                                        .foregroundStyle(MetallicTheme.accent)
                                    Text("支持 HTTP/HTTPS 订阅链接、Clash YAML 或常用节点协议链接；不支持的节点配置会提示跳过。")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineSpacing(2)
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.white.opacity(0.04))
                                )
                            }
                        }
                    }
                    .padding(20)
                }
                .disabled(busy)

                Divider().opacity(0.2)

                // 底部操作
                HStack(spacing: 12) {
                    if busy {
                        ProgressView().controlSize(.small)
                        Text("正在拉取并解析节点…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)

                    Button("取消", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)

                    LiquidGlassButton(title: "添加订阅", systemImage: "plus", variant: .prominent, size: .regular) {
                        submit()
                    }
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty || url.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(chromeBackground.opacity(chromeOpacity))
            }
        }
        .frame(width: 540, height: 480)
        .onChange(of: [name, url]) { errorText = nil }
    }

    private func submit() {
        let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        errorText = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.addSubscription(name: name.trimmingCharacters(in: .whitespacesAndNewlines), input: raw)
                dismiss()
            } catch {
                errorText = DisplayText.describe(error)
            }
        }
    }
}

// MARK: - 节点延迟与测速组件

struct NodeLatencyCell: View {
    let result: NodeSpeedResult?
    let isTesting: Bool
    let onTest: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if isTesting {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                        .frame(width: 12, height: 12)
                    Text("测速中…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if let result {
                switch result {
                case .success(let ms):
                    let color = latencyColor(ms)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(color)
                            .frame(width: 5, height: 5)
                        Text("\(ms) ms")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(color)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(color.opacity(0.12))
                            .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 0.5))
                    )

                case .timeout:
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text("超时")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.orange.opacity(0.12))
                            .overlay(Capsule().stroke(Color.orange.opacity(0.3), lineWidth: 0.5))
                    )

                case .failure(let reason):
                    HStack(spacing: 3) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 9))
                        Text("失败")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(.red)
                    .help(reason.isEmpty ? "连接失败" : reason)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.red.opacity(0.12))
                            .overlay(Capsule().stroke(Color.red.opacity(0.3), lineWidth: 0.5))
                    )
                }

                Button(action: onTest) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("重新测速")
            } else {
                Button(action: onTest) {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                        Text("测速")
                            .font(.system(size: 10.5))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.06))
                            .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.5))
                    )
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("测试该节点 TCP 握手延迟")
            }
        }
    }

    private func latencyColor(_ ms: Int) -> Color {
        if ms < 150 {
            return Color(red: 0.2, green: 0.82, blue: 0.45)
        } else if ms < 350 {
            return Color(red: 0.3, green: 0.85, blue: 0.75)
        } else if ms < 600 {
            return Color.orange
        } else {
            return Color.red
        }
    }
}
