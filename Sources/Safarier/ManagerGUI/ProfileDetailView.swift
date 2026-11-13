import AppKit
import SwiftUI
import SafarierCore
import SafarierNetwork

/// 选中环境时的详情面板：顶部 Liquid Glass 英雄横幅 + 各模块卡片支持直接内联编辑。
struct ProfileDetailView: View {
    @ObservedObject var model: ManagerModel
    let profile: Profile

    @State private var copiedFeedback: String?
    @State private var savedCardBadge: String?

    // 重命名
    @State private var isRenaming = false
    @State private var editedName = ""

    // 网络代理内联编辑
    @State private var isEditingNetwork = false
    @State private var networkOutboundKind: ProfileEditorView.OutboundKind = .direct
    @State private var networkProxyID: UUID?
    @State private var networkSubscriptionID: UUID?
    @State private var networkNodeName: String?
    @State private var showNetworkNodePicker = false
    @State private var networkErrorText: String?

    // 语言时区与机型内联编辑
    @State private var isEditingRegion = false
    @State private var regionLanguageSource: ProfileEditorView.RegionSource = .system
    @State private var regionLanguages: String = ""
    @State private var regionTimeZoneSource: ProfileEditorView.RegionSource = .system
    @State private var regionTimeZone: String = ""
    @State private var regionDeviceModel: String?
    @State private var regionErrorText: String?

    // 数据与存储内联编辑 (起始网址与备注)
    @State private var isEditingStorage = false
    @State private var storageStartURL: String = ""
    @State private var storageNotes: String = ""
    @State private var storageErrorText: String?

    var body: some View {
        let state = model.runState(profile.id)

        ScrollView {
            VStack(spacing: 20) {
                heroBanner(state)

                LazyVStack(spacing: 18) {
                    BookmarkManagerView(workspace: model.workspace, profile: profile, onOpenURL: { url in
                        if model.runState(profile.id) == .running {
                            model.bringToFront(profile)
                        } else {
                            model.launch(profile)
                        }
                    }).id(profile.id)
                    networkCard
                    regionAndDeviceCard
                    privacyCard
                    sandboxAndStorageCard
                }
            }
            .padding(24)
        }
        .onChange(of: profile.id) {
            cancelAllEditing()
        }
    }

    private func cancelAllEditing() {
        isRenaming = false
        isEditingNetwork = false
        isEditingRegion = false
        isEditingStorage = false
        networkErrorText = nil
        regionErrorText = nil
        storageErrorText = nil
    }

    private func triggerSavedBadge(_ card: String) {
        savedCardBadge = card
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if savedCardBadge == card { savedCardBadge = nil }
        }
    }

    private func latencyBadgeColor(_ ms: Int) -> Color {
        if ms < 200 {
            return Color.green
        } else if ms < 500 {
            return Color.orange
        } else {
            return Color.red
        }
    }

    private var savedIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.green)
            Text("已保存")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(
            Capsule()
                .fill(Color.green.opacity(0.12))
                .overlay(Capsule().stroke(Color.green.opacity(0.28), lineWidth: 0.7))
        )
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private func editButton(title: String = "修改", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(MetallicTheme.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.06))
                    .overlay(Capsule().stroke(MetallicTheme.badgeStroke, lineWidth: 0.6))
            )
        }
        .buttonStyle(.plain)
        .help("直接编辑此卡片配置")
    }

    // MARK: - 顶部 Liquid Glass 横幅

    private func heroBanner(_ state: RunState) -> some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                ZStack(alignment: .bottomTrailing) {
                    ProfileAvatar(profile: profile, size: 64)
                    if state != .stopped {
                        Circle()
                            .fill(state == .running ? Color.green : Color.orange)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
                            .offset(x: 3, y: 3)
                            .shadow(color: (state == .running ? Color.green : Color.orange).opacity(0.6), radius: 5)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if isRenaming {
                            HStack(spacing: 6) {
                                TextField("环境名称", text: $editedName)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 18, weight: .bold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color.black.opacity(0.35))
                                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.2), lineWidth: 0.8))
                                    )
                                    .frame(maxWidth: 240)
                                    .onSubmit { saveName() }

                                Button {
                                    saveName()
                                } label: {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.green)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    isRenaming = false
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            HStack(spacing: 6) {
                                Text(profile.name)
                                    .font(.system(size: 22, weight: .bold))
                                    .lineLimit(1)

                                Button {
                                    startRenaming()
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .padding(3)
                                }
                                .buttonStyle(.plain)
                                .help("修改环境名称")
                            }
                        }

                        ModeBadge(mode: profile.mode, large: true)
                    }

                    HStack(spacing: 8) {
                        stateBadge(state)
                        Text("·").foregroundStyle(.tertiary)
                        Text("创建于 \(profile.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 16)

                launchControl(state)
            }

            Divider().opacity(0.3)

            actionBar(state)
        }
        .padding(22)
        .background(
            LiquidGlassBackground(radius: 18, interactive: true, showsSheen: true)
        )
    }

    private func startRenaming() {
        editedName = profile.name
        isRenaming = true
    }

    private func saveName() {
        let clean = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var updated = profile
        updated.name = clean
        do {
            try model.save(updated, isNew: false)
            isRenaming = false
        } catch {
            model.report("重命名失败", error)
        }
    }

    @ViewBuilder
    private func stateBadge(_ state: RunState) -> some View {
        switch state {
        case .stopped:
            HStack(spacing: 5) {
                Circle().fill(Color.secondary.opacity(0.45)).frame(width: 7, height: 7)
                Text("未运行").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
        case .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在启动…").font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(Color.orange.opacity(0.12))
                    .overlay(Capsule().stroke(Color.orange.opacity(0.3), lineWidth: 0.7))
            )
        case .running:
            HStack(spacing: 5) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("运行中").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(Color.green.opacity(0.12))
                    .overlay(Capsule().stroke(Color.green.opacity(0.3), lineWidth: 0.7))
            )
        }
    }

    @ViewBuilder
    private func launchControl(_ state: RunState) -> some View {
        switch state {
        case .stopped:
            LiquidGlassButton(
                title: "启动浏览器",
                systemImage: "play.fill",
                variant: .prominent,
                size: .small
            ) {
                model.launch(profile)
            }
            .help("启动此环境的浏览器独立进程 (⌘R)")

        case .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在启动…")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 0.8))

        case .running:
            HStack(spacing: 8) {
                LiquidGlassButton(
                    title: "切换到窗口",
                    systemImage: "macwindow",
                    variant: .prominent,
                    size: .small
                ) {
                    model.bringToFront(profile)
                }

                LiquidGlassButton(
                    title: "结束运行",
                    systemImage: "stop.fill",
                    variant: .destructive,
                    size: .small
                ) {
                    model.stop(profile)
                }
            }
        }
    }

    private func actionBar(_ state: RunState) -> some View {
        let purging = model.purging.contains(profile.id)
        return HStack(spacing: 12) {
            Button {
                model.sheet = .editProfile(profile)
            } label: {
                Label("完整配置弹窗…", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("打开环境完整配置面板")

            Button {
                model.duplicate(profile)
            } label: {
                Label("复制环境", systemImage: "plus.square.on.square")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("复制全部设置，新环境不带原有网站数据")

            Button {
                model.confirmation = .purgeProfile(profile)
            } label: {
                Label(purging ? "正在清理…" : "清空数据…", systemImage: "eraser")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(profile.mode == .ephemeral || state != .stopped || purging)
            .help(profile.mode == .ephemeral ? "临时环境不在磁盘上保存网站数据" : "清空所有 Cookie、登录状态与缓存文件")

            Spacer()

            Button(role: .destructive) {
                model.confirmation = .deleteProfile(profile)
            } label: {
                Label("删除环境…", systemImage: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .disabled(state != .stopped || purging)
        }
    }

    // MARK: - 卡片：网络代理

    private var networkCard: some View {
        LiquidGlassCard(
            title: "网络代理",
            systemImage: "network",
            trailing: {
                if isEditingNetwork {
                    EmptyView()
                } else if savedCardBadge == "network" {
                    savedIndicator
                } else {
                    editButton {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            startEditingNetwork()
                        }
                    }
                }
            }
        ) {
            if isEditingNetwork {
                networkEditor
            } else {
                networkDisplay
            }
        }
    }

    @ViewBuilder
    private var networkDisplay: some View {
        switch model.proxyBinding(for: profile) {
            case .direct:
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(white: 0.5).opacity(0.12))
                            .frame(width: 44, height: 44)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.8)
                            )
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(MetallicTheme.accent)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("本机直连")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("通过当前本地网络直接访问")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

            case .proxy(let proxy):
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(white: 0.5).opacity(0.12))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.8)
                                )
                            Image(systemName: "network")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(MetallicTheme.accent)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(proxy.name)
                                .font(.system(size: 13.5, weight: .semibold))
                            Text(verbatim: "\(DisplayText.proxyKind(proxy.kind)) · \(proxy.host):\(proxy.port)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if let user = proxy.username {
                        Text("认证用户：\(user)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

            case .node(let subscription, let node):
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(DisplayText.nodeColor(node.type).opacity(0.14))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(DisplayText.nodeColor(node.type).opacity(0.35), lineWidth: 0.8)
                                )
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(DisplayText.nodeColor(node.type))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(node.name)
                                    .font(.system(size: 14, weight: .semibold))
                                ProtocolBadge(type: node.type)
                                if let speed = model.nodeSpeeds[node.id], let ms = speed.latencyMs {
                                    Text("\(ms) ms")
                                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(latencyBadgeColor(ms))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background(Capsule().fill(Color.white.opacity(0.08)))
                                }
                            }
                            Text(verbatim: "\(node.server):\(node.serverPort)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text("来自订阅「\(subscription.name)」")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "shield.checkered")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("由独立网络进程安全转发，防止 DNS 与流量泄露")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 0.5))
                    )
                }

            case .missing(_):
                Label("绑定的代理已失效，请重新设置", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline)

            case .missingNode(let subscription, let node):
                Label(
                    subscription.map { "订阅「\($0)」中未找到节点「\(node)」" } ?? "绑定的订阅已失效，请重新选择",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.subheadline)
            }
    }

    private var networkEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("出站模式")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Picker("出站模式", selection: $networkOutboundKind) {
                    Text("本机直连").tag(ProfileEditorView.OutboundKind.direct)
                    Text("独立代理").tag(ProfileEditorView.OutboundKind.proxy)
                    Text("订阅节点").tag(ProfileEditorView.OutboundKind.node)
                }
                .pickerStyle(.segmented)
            }

            switch networkOutboundKind {
            case .direct:
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("通过当前本地网络直接访问，不经过任何代理转发。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))

            case .proxy:
                VStack(alignment: .leading, spacing: 6) {
                    Text("选择独立代理")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    if model.proxies.isEmpty {
                        Text("暂无独立代理，可前往管理器代理设置添加或切换至订阅节点。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Picker("代理配置", selection: $networkProxyID) {
                            Text("请选择代理").tag(UUID?.none)
                            ForEach(model.proxies) { proxy in
                                Text(verbatim: "\(proxy.name) — \(DisplayText.proxyKind(proxy.kind)) \(proxy.host):\(proxy.port)")
                                    .tag(UUID?.some(proxy.id))
                            }
                        }
                    }
                }

            case .node:
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("所属订阅")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        if model.subscriptions.isEmpty {
                            Text("暂无可用订阅，请先在订阅管理中添加。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Picker("所属订阅", selection: $networkSubscriptionID) {
                                Text("请选择订阅").tag(UUID?.none)
                                ForEach(model.subscriptions) { sub in
                                    Text(verbatim: "\(sub.name)（\(sub.nodes.count) 个节点）")
                                        .tag(UUID?.some(sub.id))
                                }
                            }
                            .onChange(of: networkSubscriptionID) {
                                if let nodes = networkSubscriptionID.flatMap(model.subscription)?.nodes, nodes.count == 1 {
                                    networkNodeName = nodes[0].name
                                } else if let name = networkNodeName, networkSubscriptionID.flatMap(model.subscription)?.nodes.contains(where: { $0.name == name }) != true {
                                    networkNodeName = nil
                                }
                            }
                        }
                    }

                    if let selectedSub = networkSubscriptionID.flatMap(model.subscription) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("节点选择")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)

                            Button {
                                showNetworkNodePicker = true
                            } label: {
                                nodePickerLabel(selectedSub: selectedSub)
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showNetworkNodePicker, arrowEdge: .trailing) {
                                NodePickerView(nodes: selectedSub.nodes, selection: networkNodeName, nodeSpeeds: model.nodeSpeeds) { name in
                                    networkNodeName = name
                                    showNetworkNodePicker = false
                                }
                            }
                        }
                    }
                }
            }

            if let networkErrorText {
                Text(networkErrorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider().opacity(0.3)

            HStack {
                if model.runState(profile.id) != .stopped {
                    Text("环境正在运行，修改将在下次启动时生效")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("取消") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isEditingNetwork = false
                        networkErrorText = nil
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)

                LiquidGlassButton(
                    title: "保存修改",
                    systemImage: "checkmark",
                    variant: .prominent,
                    size: .small
                ) {
                    saveNetwork()
                }
            }
        }
    }

    @ViewBuilder
    private func nodePickerLabel(selectedSub: Subscription) -> some View {
        let node = selectedSub.nodes.first(where: { $0.name == networkNodeName })
        HStack(spacing: 8) {
            if let node = node {
                Text(node.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                ProtocolBadge(type: node.type)
                if let speed = model.nodeSpeeds[node.id], let ms = speed.latencyMs {
                    Text("\(ms) ms")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(latencyBadgeColor(ms))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            } else {
                Text(networkNodeName.map { "「\($0)」未在订阅中" } ?? "请选择节点…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.7))
        )
    }

    private func startEditingNetwork() {
        networkOutboundKind = profile.subscriptionID != nil ? .node : profile.proxyID != nil ? .proxy : .direct
        networkProxyID = profile.proxyID
        networkSubscriptionID = profile.subscriptionID
        networkNodeName = profile.nodeName
        networkErrorText = nil
        isEditingNetwork = true
    }

    private func saveNetwork() {
        networkErrorText = nil
        var updated = profile
        switch networkOutboundKind {
        case .direct:
            updated.proxyID = nil
            updated.subscriptionID = nil
            updated.nodeName = nil
        case .proxy:
            guard networkProxyID != nil else {
                networkErrorText = "请选择代理。"
                return
            }
            updated.proxyID = networkProxyID
            updated.subscriptionID = nil
            updated.nodeName = nil
        case .node:
            guard networkSubscriptionID != nil, networkNodeName != nil else {
                networkErrorText = "请选择订阅和节点。"
                return
            }
            updated.proxyID = nil
            updated.subscriptionID = networkSubscriptionID
            updated.nodeName = networkNodeName
        }
        do {
            try model.save(updated, isNew: false)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isEditingNetwork = false
                triggerSavedBadge("network")
            }
        } catch {
            networkErrorText = DisplayText.describe(error)
        }
    }

    // MARK: - 卡片：区域与机型模拟

    private var regionAndDeviceCard: some View {
        LiquidGlassCard(
            title: "语言时区与机型",
            systemImage: "globe",
            trailing: {
                if isEditingRegion {
                    EmptyView()
                } else if savedCardBadge == "region" {
                    savedIndicator
                } else {
                    editButton {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            startEditingRegion()
                        }
                    }
                }
            }
        ) {
            if isEditingRegion {
                regionAndDeviceEditor
            } else {
                regionAndDeviceDisplay
            }
        }
    }

    private var regionAndDeviceDisplay: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 语言与时区
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("语言环境")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Image(systemName: "character.bubble")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(DisplayText.languages(of: profile))
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 5) {
                    Text("时区设置")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(DisplayText.timeZone(of: profile))
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().opacity(0.3)

            // 机型模拟
            VStack(alignment: .leading, spacing: 8) {
                Text("模拟机型")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                if let model = profile.deviceModel.flatMap(MacDeviceModel.preset) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: model.category.contains("MacBook") ? "laptopcomputer" : "desktopcomputer")
                                .font(.system(size: 16))
                                .foregroundStyle(.tint)
                            Text(model.name)
                                .font(.system(size: 14, weight: .semibold))
                        }

                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                            GridRow {
                                Text("芯片规格").font(.caption).foregroundStyle(.secondary)
                                Text(DisplayText.hardware(model)).font(.system(size: 12))
                            }
                            GridRow {
                                Text("色彩与屏幕").font(.caption).foregroundStyle(.secondary)
                                Text(DisplayText.screen(model)).font(.system(size: 12))
                            }
                            GridRow {
                                Text("推荐视口").font(.caption).foregroundStyle(.secondary)
                                Text(DisplayText.viewport(model)).font(.system(size: 12, design: .monospaced))
                            }
                            GridRow {
                                Text("网页探测值").font(.caption).foregroundStyle(.secondary)
                                Text(DisplayText.webVisible(model)).font(.system(size: 12, design: .monospaced))
                            }
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "macmini")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                        Text("跟随本机硬件")
                            .font(.system(size: 13, weight: .medium))
                    }
                }

                Text(DisplayText.deviceModelNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineSpacing(2)
                    .padding(.top, 2)
            }
        }
    }

    private var regionAndDeviceEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 语言设置
            VStack(alignment: .leading, spacing: 6) {
                Text("语言环境")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Picker("语言来源", selection: $regionLanguageSource) {
                    Text(DisplayText.followProxy).tag(ProfileEditorView.RegionSource.proxy)
                    Text("跟随系统").tag(ProfileEditorView.RegionSource.system)
                    Text("自定义").tag(ProfileEditorView.RegionSource.custom)
                }
                .pickerStyle(.segmented)

                if regionLanguageSource == .custom {
                    HStack(spacing: 6) {
                        TextField("语言标签（如 en-US, en）", text: $regionLanguages)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.black.opacity(0.25))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.8))
                            )

                        Menu {
                            ForEach(ProfileEditorView.languagePresets, id: \.value) { preset in
                                Button("\(preset.title)  \(preset.value)") { regionLanguages = preset.value }
                            }
                        } label: {
                            Image(systemName: "character.bubble")
                                .padding(5)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("常用语言预设")
                    }
                }
            }

            // 时区设置
            VStack(alignment: .leading, spacing: 6) {
                Text("时区设置")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Picker("时区来源", selection: $regionTimeZoneSource) {
                    Text(DisplayText.followProxy).tag(ProfileEditorView.RegionSource.proxy)
                    Text("跟随系统").tag(ProfileEditorView.RegionSource.system)
                    Text("自定义").tag(ProfileEditorView.RegionSource.custom)
                }
                .pickerStyle(.segmented)

                if regionTimeZoneSource == .custom {
                    HStack(spacing: 6) {
                        TextField("时区标识（如 America/Los_Angeles）", text: $regionTimeZone)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.black.opacity(0.25))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.8))
                            )

                        TimeZoneMenu(selection: $regionTimeZone)
                    }
                }
            }

            // 模拟机型
            VStack(alignment: .leading, spacing: 6) {
                Text("模拟机型")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Picker("模拟机型", selection: $regionDeviceModel) {
                    Text("跟随本机硬件").tag(String?.none)
                    ForEach(MacDeviceModel.categories, id: \.self) { category in
                        Section(category) {
                            ForEach(MacDeviceModel.presets.filter { $0.category == category }) { preset in
                                Text(preset.name).tag(String?.some(preset.id))
                            }
                        }
                    }
                }

                if let preset = regionDeviceModel.flatMap(MacDeviceModel.preset) {
                    VStack(alignment: .leading, spacing: 6) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                            GridRow {
                                Text("芯片规格").font(.caption2).foregroundStyle(.secondary)
                                Text(DisplayText.hardware(preset)).font(.system(size: 11.5))
                            }
                            GridRow {
                                Text("色彩与屏幕").font(.caption2).foregroundStyle(.secondary)
                                Text(DisplayText.screen(preset)).font(.system(size: 11.5))
                            }
                            GridRow {
                                Text("推荐视口").font(.caption2).foregroundStyle(.secondary)
                                Text(DisplayText.viewport(preset)).font(.system(size: 11.5, design: .monospaced))
                            }
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.04)))
                }
            }

            if let regionErrorText {
                Text(regionErrorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider().opacity(0.3)

            HStack {
                if model.runState(profile.id) != .stopped {
                    Text("环境正在运行，修改将在下次启动时生效")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("取消") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isEditingRegion = false
                        regionErrorText = nil
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)

                LiquidGlassButton(
                    title: "保存修改",
                    systemImage: "checkmark",
                    variant: .prominent,
                    size: .small
                ) {
                    saveRegion()
                }
            }
        }
    }

    private func startEditingRegion() {
        regionLanguageSource = profile.followProxyLanguages ? .proxy : profile.languages.isEmpty ? .system : .custom
        regionLanguages = profile.languages.joined(separator: ", ")
        regionTimeZoneSource = profile.followProxyTimeZone ? .proxy : profile.timeZoneIdentifier == nil ? .system : .custom
        regionTimeZone = profile.timeZoneIdentifier ?? ""
        regionDeviceModel = profile.deviceModel
        regionErrorText = nil
        isEditingRegion = true
    }

    private func saveRegion() {
        regionErrorText = nil
        if (regionLanguageSource == .proxy || regionTimeZoneSource == .proxy) &&
            profile.proxyID == nil && profile.subscriptionID == nil {
            regionErrorText = "「跟随代理」需要先在网络卡片中选择代理或节点。"
            return
        }
        if let err = ProfileEditorView.customRegionError(
            languageSource: regionLanguageSource,
            languages: regionLanguages,
            timeZoneSource: regionTimeZoneSource,
            timeZone: regionTimeZone
        ) {
            regionErrorText = err
            return
        }

        var updated = profile
        updated.followProxyLanguages = regionLanguageSource == .proxy
        updated.languages = regionLanguageSource != .custom ? [] : regionLanguages.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        updated.followProxyTimeZone = regionTimeZoneSource == .proxy
        let zone = regionTimeZone.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.timeZoneIdentifier = regionTimeZoneSource != .custom || zone.isEmpty ? nil : zone
        updated.deviceModel = regionDeviceModel
        if regionDeviceModel != nil {
            updated.spi.insert(.fingerprintingProtections)
        }
        do {
            try model.save(updated, isNew: false)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isEditingRegion = false
                triggerSavedBadge("region")
            }
        } catch {
            regionErrorText = DisplayText.describe(error)
        }
    }

    // MARK: - 卡片：WebKit 原生隐私能力 (直接点按开关交互)

    private var privacyCard: some View {
        let activeCount = SPIFeatures.tokens.filter { profile.spi.contains($0.feature) }.count

        return LiquidGlassCard(
            title: "隐私安全与防追踪",
            systemImage: "shield.lefthalf.filled",
            badge: "\(activeCount)/\(SPIFeatures.tokens.count) 项已开启",
            trailing: {
                HStack(spacing: 8) {
                    if savedCardBadge == "privacy" {
                        savedIndicator
                    }

                    Button {
                        toggleAllSPIFeatures(enableAll: activeCount < SPIFeatures.tokens.count)
                    } label: {
                        Text(activeCount < SPIFeatures.tokens.count ? "全部开启" : "恢复默认")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MetallicTheme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.06))
                                    .overlay(Capsule().stroke(MetallicTheme.badgeStroke, lineWidth: 0.6))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("一键切换推荐安全防护")
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 10) {
                    ForEach(SPIFeatures.tokens, id: \.name) { token in
                        spiGridItem(token.feature)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("直接点击上方卡片即可开启或关闭防护项，修改即时自动保存并在下次启动时生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 0.5))
                )
            }
        }
    }

    private func spiGridItem(_ feature: SPIFeatures) -> some View {
        let text = DisplayText.spi(feature)
        let enabled = profile.spi.contains(feature)
        let accent = MetallicTheme.accent

        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                toggleSPIFeature(feature)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(enabled ? accent : Color.secondary.opacity(0.4))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(text.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(enabled ? .primary : .secondary)
                        Spacer()
                    }
                    Text(text.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(enabled ? Color.white.opacity(0.06) : Color.white.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(enabled ? 0.38 : 0.14), location: 0.0),
                                .init(color: enabled ? accent.opacity(0.22) : Color.clear, location: 0.5),
                                .init(color: Color.white.opacity(enabled ? 0.10 : 0.04), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.7
                    )
            )
        }
        .buttonStyle(.plain)
        .help(enabled ? "点击关闭「\(text.title)」" : "点击开启「\(text.title)」")
    }

    private func toggleSPIFeature(_ feature: SPIFeatures) {
        var updated = profile
        if updated.spi.contains(feature) {
            updated.spi.remove(feature)
        } else {
            updated.spi.insert(feature)
        }
        do {
            try model.save(updated, isNew: false)
            triggerSavedBadge("privacy")
        } catch {
            model.report("更新隐私设置失败", error)
        }
    }

    private func toggleAllSPIFeatures(enableAll: Bool) {
        var updated = profile
        if enableAll {
            for token in SPIFeatures.tokens {
                updated.spi.insert(token.feature)
            }
        } else {
            updated.spi = ProfileEditorView.defaultSPI(for: profile.mode)
        }
        do {
            try model.save(updated, isNew: false)
            triggerSavedBadge("privacy")
        } catch {
            model.report("更新隐私设置失败", error)
        }
    }

    // MARK: - 卡片：沙盒存储与运行日志

    private var sandboxAndStorageCard: some View {
        LiquidGlassCard(
            title: "数据与存储",
            systemImage: "internaldrive",
            trailing: {
                if isEditingStorage {
                    EmptyView()
                } else if savedCardBadge == "storage" {
                    savedIndicator
                } else {
                    editButton {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            startEditingStorage()
                        }
                    }
                }
            }
        ) {
            if isEditingStorage {
                sandboxAndStorageEditor
            } else {
                sandboxAndStorageDisplay
            }
        }
    }

    private var sandboxAndStorageDisplay: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 模式
            HStack(alignment: .top) {
                Text("沙盒模式")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(DisplayText.mode(profile.mode) + "模式")
                        .font(.system(size: 13, weight: .medium))
                    Text(DisplayText.modeDetail(profile.mode))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 网站数据目录
            if profile.mode == .persistent {
                HStack(alignment: .center) {
                    Text("网站数据")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    fileLocationRow(DisplayText.webKitDataDirectory(for: profile.id), missing: "暂无数据（首次启动后生成）")
                }
            }

            // 运行日志
            HStack(alignment: .center) {
                Text("运行日志")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                    fileLocationRow(model.workspace.runnerLogURL(for: profile.id), missing: "暂无日志文件")
                }

            // 起始网址
            HStack(alignment: .center) {
                Text("起始网址")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                if let url = profile.startURL {
                    HStack(spacing: 8) {
                        Text(url.absoluteString)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        copyButton(url.absoluteString)
                    }
                } else {
                    Text("默认空白页")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 备注
            if !profile.notes.isEmpty {
                HStack(alignment: .top) {
                    Text("环境备注")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Text(profile.notes)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                }
            }

            // 环境 ID
            HStack(alignment: .center) {
                Text("环境 ID")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                HStack(spacing: 6) {
                    Text(profile.id.uuidString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    copyButton(profile.id.uuidString)
                }
            }
        }
    }

    private var sandboxAndStorageEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("起始网址")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                TextField("https://… （留空则为默认空白页）", text: $storageStartURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(0.25))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.8))
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("环境备注")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                TextField("环境备注说明…", text: $storageNotes, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(2...4)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(0.25))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.8))
                    )
            }

            if let storageErrorText {
                Text(storageErrorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider().opacity(0.3)

            HStack {
                Text("沙盒模式：\(DisplayText.mode(profile.mode))模式（创建后固定）")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button("取消") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isEditingStorage = false
                        storageErrorText = nil
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)

                LiquidGlassButton(
                    title: "保存修改",
                    systemImage: "checkmark",
                    variant: .prominent,
                    size: .small
                ) {
                    saveStorage()
                }
            }
        }
    }

    private func startEditingStorage() {
        storageStartURL = profile.startURL?.absoluteString ?? ""
        storageNotes = profile.notes
        storageErrorText = nil
        isEditingStorage = true
    }

    private func saveStorage() {
        storageErrorText = nil
        var url: URL?
        let rawURL = storageStartURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawURL.isEmpty {
            url = rawURL.contains("://") ? URL(string: rawURL) : URL(string: "https://" + rawURL)
            guard url != nil else {
                storageErrorText = "起始网址不合法：\(rawURL)"
                return
            }
        }
        var updated = profile
        updated.startURL = url
        updated.notes = storageNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try model.save(updated, isNew: false)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isEditingStorage = false
                triggerSavedBadge("storage")
            }
        } catch {
            storageErrorText = DisplayText.describe(error)
        }
    }

    // MARK: - 辅助小视图

    private func fileLocationRow(_ url: URL, missing: String) -> some View {
        HStack(spacing: 8) {
            let exists = FileManager.default.fileExists(atPath: url.path)
            Text(exists ? url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") : missing)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(exists ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if exists {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("在访达中显示")

                copyButton(url.path)
            }
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copiedFeedback = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copiedFeedback == text { copiedFeedback = nil }
            }
        } label: {
            Image(systemName: copiedFeedback == text ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(copiedFeedback == text ? .green : .secondary)
        }
        .buttonStyle(.borderless)
        .help("拷贝")
    }
}
