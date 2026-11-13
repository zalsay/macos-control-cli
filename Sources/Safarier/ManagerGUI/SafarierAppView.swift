import SwiftUI
import SafarierCore

/// 主管理窗口：参考 Codex UI 设计的左侧窄图标菜单栏 + 次级导航与内容详情分区展示。
struct SafarierAppView: View {
    @ObservedObject var model: ManagerModel
    @Environment(\.colorScheme) private var colorScheme

    /// 亮银钛金与液态玻璃设计规范：顶部控制栏与最左侧窄侧边栏共享的深邃黑曜石钛金冷调外壳背景 (#0C1018 / rgb(12, 16, 24))
    private var chromeBackground: Color {
        MetallicTheme.chromeBackground(for: colorScheme)
    }

    /// 亮银钛金与液态玻璃设计规范：主展示区域略微内凹沉降的深邃黑曜石蓝黑底色 (#070A10 / rgb(7, 10, 16))
    private var contentBackground: Color {
        colorScheme == .dark
            ? Color(red: 0x07 / 255.0, green: 0x0A / 255.0, blue: 0x10 / 255.0).opacity(0.95)
            : Color(red: 0xFA / 255.0, green: 0xFB / 255.0, blue: 0xFD / 255.0).opacity(0.95)
    }

    /// 贴近控制栏背景色的精密细边框
    private var contentBorderColor: Color {
        colorScheme == .dark
            ? Color(red: 0x20 / 255.0, green: 0x2A / 255.0, blue: 0x3C / 255.0).opacity(0.75)
            : Color(red: 0xD0 / 255.0, green: 0xDA / 255.0, blue: 0xE8 / 255.0).opacity(0.85)
    }

    var body: some View {
        ZStack {
            // 顶部控制栏与侧边菜单栏统一底色（原生 macOS 微半透明磨砂玻璃材质）
            VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)

            chromeBackground
                .opacity(MetallicTheme.chromeOpacity(for: colorScheme))

            VStack(spacing: 0) {
                // 顶部原生统一控制栏 (Top Bar，贯穿全窗包括右侧区域)
                WindowTopBar(model: model)
                    .frame(height: 38)

                HStack(spacing: 0) {
                    // 最左侧窄图标菜单栏 (Activity Bar，仅保留 icon)
                    ManagerActivityBar(model: model)
                        .frame(width: 52)

                    // 主分区展示内容区 (带有内圆角与微妙边框的独立容器)
                    mainContainer
                }
            }
        }
        .ignoresSafeArea(.all)
        .tint(MetallicTheme.accent)
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .newProfile: ProfileEditorView(model: model, original: nil)
            case .editProfile(let profile): ProfileEditorView(model: model, original: profile)
            case .newSubscription: SubscriptionEditorView(model: model)
            case .jevConfig: JEVConfigView()
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } }),
            presenting: model.confirmation,
            actions: confirmationActions,
            message: confirmationMessage
        )
        .alert(
            model.message?.title ?? "",
            isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } }),
            presenting: model.message,
            actions: { _ in Button("好") {} },
            message: { Text($0.detail) }
        )
        .onAppear { model.startMonitoring() }
    }

    private var mainContainer: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 10, style: .continuous)
        return mainContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(contentBackground)
            .clipShape(shape)
            .overlay(
                shape
                    .strokeBorder(contentBorderColor, lineWidth: 1)
            )
    }

    @ViewBuilder
    private var mainContent: some View {
        switch model.selectedTab {
        case .profiles:
            ProfilesSectionView(model: model)
        case .subscriptions:
            SubscriptionsSectionView(model: model)
        case .dsh:
            // 智能体（dsh）直接全屏显示 dsh 的 Web 页面
            DshContainerView()
        case .settings:
            SettingsSectionView(model: model)
        }
    }

    // MARK: - 确认框

    private var confirmationTitle: String {
        switch model.confirmation {
        case .deleteProfile(let profile): return "删除环境「\(profile.name)」？"
        case .purgeProfile(let profile): return "清理「\(profile.name)」的数据？"
        case .deleteSubscription(let subscription): return "删除订阅「\(subscription.name)」？"
        case nil: return ""
        }
    }

    @ViewBuilder
    private func confirmationActions(_ confirmation: ManagerModel.Confirmation) -> some View {
        switch confirmation {
        case .deleteProfile(let profile):
            if profile.mode == .persistent {
                Button("删除并清除网站数据", role: .destructive) { model.delete(profile, purgeData: true) }
                Button("只删除环境，保留数据") { model.delete(profile, purgeData: false) }
            } else {
                Button("删除", role: .destructive) { model.delete(profile, purgeData: false) }
            }
        case .purgeProfile(let profile):
            Button("清理", role: .destructive) { model.purgeData(profile) }
        case .deleteSubscription(let subscription):
            Button("删除", role: .destructive) { model.delete(subscription) }
        }
        Button("取消", role: .cancel) {}
    }

    private func confirmationMessage(_ confirmation: ManagerModel.Confirmation) -> some View {
        switch confirmation {
        case .deleteProfile(let profile):
            return Text(profile.mode == .persistent
                ? "将删除该环境配置。您可以选择同时清除网站登录数据，或继续保留在本地。"
                : "将删除该临时环境配置。")
        case .purgeProfile:
            return Text("将清除此环境下的所有登录状态、Cookie 与缓存文件，配置将保留。")
        case .deleteSubscription:
            return Text("将从本地移除该订阅链接与缓存节点。")
        }
    }
}

// MARK: - 顶部原生统一控制栏 (Top Bar)

struct WindowTopBar: View {
    @ObservedObject var model: ManagerModel

    var body: some View {
        HStack(spacing: 0) {
            // macOS 窗口红黄绿三色控制按钮避让区
            Color.clear
                .frame(width: 76)

            Spacer()
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 最左侧窄图标菜单栏 (Activity Bar)

enum ActivityBarBadge {
    case none
    case dot(Color)
    case progress
}

struct ManagerActivityBar: View {
    @ObservedObject var model: ManagerModel
    @ObservedObject private var dshService = DshService.shared

    var body: some View {
        VStack(spacing: 12) {
            // 环境 (Profiles)
            ActivityBarItem(
                systemImage: "square.stack.3d.up.fill",
                title: "环境 (沙盒多开)",
                isSelected: model.selectedTab == .profiles,
                badge: model.running.isEmpty ? .none : .dot(.green)
            ) {
                model.switchTab(.profiles)
            }

            // 订阅 (Subscriptions)
            ActivityBarItem(
                systemImage: "antenna.radiowaves.left.and.right",
                title: "节点订阅",
                isSelected: model.selectedTab == .subscriptions,
                badge: model.refreshing.isEmpty ? .none : .progress
            ) {
                model.switchTab(.subscriptions)
            }

            // 智能体 (DeepSeek Harness)
            ActivityBarItem(
                systemImage: "sparkles.rectangle.stack",
                title: "智能体 (DeepSeek Harness)",
                isSelected: model.selectedTab == .dsh,
                badge: dshBadgeState
            ) {
                model.switchTab(.dsh)
            }
            .contextMenu {
                dshContextMenu
            }

            Spacer(minLength: 12)

            // 设置 (放底部)
            ActivityBarItem(
                systemImage: model.selectedTab == .settings ? "gearshape.fill" : "gearshape",
                title: "设置",
                isSelected: model.selectedTab == .settings,
                badge: .none
            ) {
                model.switchTab(.settings)
            }
            .padding(.bottom, 12)
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dshBadgeState: ActivityBarBadge {
        switch dshService.status {
        case .running:
            return .dot(.green)
        case .starting:
            return .progress
        case .stopped, .failed:
            return .none
        }
    }

    @ViewBuilder
    private var dshContextMenu: some View {
        if case .running(let url) = dshService.status {
            Button {
                dshService.reloadWeb()
            } label: {
                Label("刷新页面", systemImage: "arrow.clockwise")
            }

            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("在浏览器中打开", systemImage: "arrow.up.right.square")
            }

            Divider()

            Button {
                dshService.restart()
            } label: {
                Label("重启服务", systemImage: "arrow.triangle.2.circlepath")
            }

            Button(role: .destructive) {
                dshService.stop()
            } label: {
                Label("停止", systemImage: "stop.fill")
            }
        } else if case .starting = dshService.status {
            Button(role: .destructive) {
                dshService.stop()
            } label: {
                Label("取消启动", systemImage: "stop.fill")
            }
        } else {
            Button {
                dshService.start()
            } label: {
                Label("启动 Harness", systemImage: "play.fill")
            }
        }
    }
}

struct ActivityBarItem: View {
    let systemImage: String
    let title: String
    let isSelected: Bool
    var badge: ActivityBarBadge = .none
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    if isSelected {
                        LiquidGlassBackground(radius: 9, showsSheen: true, bevelWidth: 1.0, hasShadow: false)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    }

                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? MetallicTheme.specularLight : (isHovered ? .primary : .secondary))
                }
                .frame(width: 36, height: 36)

                switch badge {
                case .none:
                    EmptyView()
                case .dot(let color):
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1.5))
                        .shadow(color: color.opacity(0.6), radius: 3)
                        .offset(x: 2, y: 2)
                case .progress:
                    ProgressView()
                        .controlSize(.mini)
                        .offset(x: 2, y: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 环境分区 (左右栏显示)

struct ProfilesSectionView: View {
    @ObservedObject var model: ManagerModel
    @State private var searchText = ""

    private var filteredProfiles: [Profile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.profiles }
        return model.profiles.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.notes.localizedCaseInsensitiveContains(query) ||
            DisplayText.proxyName(model.proxyBinding(for: $0)).localizedCaseInsensitiveContains(query) ||
            DisplayText.shortTimeZone(of: $0).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // 左列：环境列表
            VStack(spacing: 0) {
                // 顶部标题与操作
                HStack(spacing: 8) {
                    Text("环境")
                        .font(.system(size: 15, weight: .bold))

                    Text("\(filteredProfiles.count)")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.05))
                                .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.5))
                        )

                    Spacer()

                    Button {
                        model.sheet = .newProfile
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MetallicTheme.darkText)
                            .frame(width: 24, height: 24)
                            .background(
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(MetallicTheme.prominentGradient)
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(MetallicTheme.anisotropicSheen())
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(MetallicTheme.metallicRimBorder, lineWidth: 0.8)
                                }
                            )
                    }
                    .buttonStyle(.plain)
                    .help("新建环境 (⌘N)")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

                // 搜索栏
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                    TextField("搜索环境或节点…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 0.6))
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

                Divider().opacity(0.2)

                // 环境列表
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(filteredProfiles) { profile in
                            ProfileSidebarItem(
                                model: model,
                                profile: profile,
                                isSelected: model.selection == .profile(profile.id)
                            )
                        }

                        if filteredProfiles.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "tray")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.tertiary)
                                Text(searchText.isEmpty ? "还没有环境" : "未匹配到环境")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 40)
                        }
                    }
                    .padding(8)
                }

                // 底部运行中指示
                if !model.running.isEmpty {
                    Divider().opacity(0.2)
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text("\(model.running.count) 个环境运行中")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.green)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
            .frame(width: 270)
            .background(Color.black.opacity(0.10))

            Divider().opacity(0.25)

            // 右列：环境详情
            Group {
                if case .profile(let id) = model.selection, let profile = model.profile(id) {
                    ProfileDetailView(model: model, profile: profile)
                } else {
                    ProfilesPlaceholderView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ProfileSidebarItem: View {
    @ObservedObject var model: ManagerModel
    let profile: Profile
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            model.selection = .profile(profile.id)
        } label: {
            ProfileRow(
                profile: profile,
                proxy: model.proxyBinding(for: profile),
                state: model.runState(profile.id)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Group {
                if isSelected {
                    LiquidGlassBackground(radius: 8, showsSheen: true, bevelWidth: 1.0, hasShadow: false)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                }
            }
        )
        .onHover { isHovered = $0 }
        .contextMenu {
            let state = model.runState(profile.id)
            if state == .running {
                Button("切换到窗口") { model.bringToFront(profile) }
                Button("结束运行") { model.stop(profile) }
            } else {
                Button("启动浏览器") { model.launch(profile) }
                    .disabled(state != .stopped)
            }
            Button("编辑…") { model.sheet = .editProfile(profile) }
            Button("复制环境") { model.duplicate(profile) }
            Divider()
            Button("清理沙盒数据…") { model.confirmation = .purgeProfile(profile) }
                .disabled(profile.mode == .ephemeral || state != .stopped)
            Button("删除环境…", role: .destructive) { model.confirmation = .deleteProfile(profile) }
                .disabled(state != .stopped)
        }
    }
}

// MARK: - 订阅分区 (左右栏显示)

struct SubscriptionsSectionView: View {
    @ObservedObject var model: ManagerModel
    @State private var searchText = ""

    private var filteredSubscriptions: [Subscription] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.subscriptions }
        return model.subscriptions.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.nodes.contains { $0.name.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // 左列：订阅列表
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 8) {
                    Text("订阅")
                        .font(.system(size: 15, weight: .bold))

                    Text("\(filteredSubscriptions.count)")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.05))
                                .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.5))
                        )

                    Spacer()

                    Button {
                        model.sheet = .newSubscription
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MetallicTheme.darkText)
                            .frame(width: 24, height: 24)
                            .background(
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(MetallicTheme.prominentGradient)
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(MetallicTheme.anisotropicSheen())
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(MetallicTheme.metallicRimBorder, lineWidth: 0.8)
                                }
                            )
                    }
                    .buttonStyle(.plain)
                    .help("添加订阅")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

                // 搜索框
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                    TextField("搜索订阅或节点…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 0.6))
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

                Divider().opacity(0.2)

                // 列表
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(filteredSubscriptions) { sub in
                            SubscriptionSidebarItem(
                                model: model,
                                subscription: sub,
                                isSelected: model.selection == .subscription(sub.id)
                            )
                        }

                        if filteredSubscriptions.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.tertiary)
                                Text(searchText.isEmpty ? "还没有订阅" : "未匹配到订阅")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 40)
                        }
                    }
                    .padding(8)
                }
            }
            .frame(width: 270)
            .background(Color.black.opacity(0.10))

            Divider().opacity(0.25)

            // 右列：订阅详情
            Group {
                if case .subscription(let id) = model.selection, let sub = model.subscription(id) {
                    SubscriptionDetailView(model: model, subscription: sub)
                } else {
                    SubscriptionsPlaceholderView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SubscriptionSidebarItem: View {
    @ObservedObject var model: ManagerModel
    let subscription: Subscription
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            model.selection = .subscription(subscription.id)
        } label: {
            SubscriptionRow(
                subscription: subscription,
                refreshing: model.refreshing.contains(subscription.id)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Group {
                if isSelected {
                    LiquidGlassBackground(radius: 8, showsSheen: true, bevelWidth: 1.0, hasShadow: false)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                }
            }
        )
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("刷新订阅") { model.refresh(subscription) }
            Divider()
            Button("删除订阅…", role: .destructive) { model.confirmation = .deleteSubscription(subscription) }
        }
    }
}

// MARK: - 设置分区 (参考 Codex 左右栏显示)

enum SettingsCategory: String, CaseIterable, Identifiable {
    case jev = "jev"
    case network = "network"
    case privacy = "privacy"
    case about = "about"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jev: return "JEV 视觉模型"
        case .network: return "网络与代理"
        case .privacy: return "隐私与指纹防护"
        case .about: return "关于 Safarier"
        }
    }

    var systemImage: String {
        switch self {
        case .jev: return "sparkles.rectangle.stack"
        case .network: return "network"
        case .privacy: return "shield.lefthalf.filled"
        case .about: return "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .jev: return "自动化视觉定位模型与 API"
        case .network: return "sing-box 核心进程与节点转发"
        case .privacy: return "Safari 原生反指纹扰动防护"
        case .about: return "版本 1.0.1 · 通用架构"
        }
    }
}

struct SettingsSectionView: View {
    @ObservedObject var model: ManagerModel
    @State private var category: SettingsCategory = .jev
    @State private var searchText = ""

    private var filteredCategories: [SettingsCategory] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SettingsCategory.allCases }
        return SettingsCategory.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // 左列：设置导航列表 (270pt 宽度，与环境和订阅完全对齐)
            VStack(spacing: 0) {
                // 顶部标题与数量指示
                HStack(spacing: 8) {
                    Text("设置")
                        .font(.system(size: 15, weight: .bold))

                    Text("\(SettingsCategory.allCases.count)")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.05))
                                .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.5))
                        )

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

                // 搜索栏
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                    TextField("搜索设置…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 0.6))
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

                Divider().opacity(0.2)

                // 设置分类列表
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        let filtered = filteredCategories

                        if filtered.contains(.jev) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("集成与辅助")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 4)

                                settingsItem(.jev)
                            }
                        }

                        if filtered.contains(where: { $0 == .network || $0 == .privacy }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("核心与安全")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)

                                if filtered.contains(.network) { settingsItem(.network) }
                                if filtered.contains(.privacy) { settingsItem(.privacy) }
                            }
                        }

                        if filtered.contains(.about) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("系统")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)

                                settingsItem(.about)
                            }
                        }

                        if filtered.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.tertiary)
                                Text("未匹配到设置项")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        }
                    }
                    .padding(8)
                }
            }
            .frame(width: 270)
            .background(Color.black.opacity(0.10))

            Divider().opacity(0.25)

            // 右列：设置详情 (各子面板独立提供 ScrollView 与 padding(24)，与环境面板完全对齐)
            Group {
                switch category {
                case .jev:
                    JEVConfigView(embedded: true)
                case .network:
                    NetworkSettingsDetailView(model: model)
                case .privacy:
                    PrivacySettingsDetailView()
                case .about:
                    AboutSettingsDetailView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func settingsItem(_ item: SettingsCategory) -> some View {
        SettingsSidebarItem(
            item: item,
            isSelected: category == item
        ) {
            category = item
        }
    }
}

// MARK: - 设置侧边栏行组件

struct SettingsSidebarItem: View {
    let item: SettingsCategory
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(MetallicTheme.prominentGradient)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(MetallicTheme.metallicRimBorder, lineWidth: 0.8)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
                            )
                    }
                    Image(systemName: item.systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? MetallicTheme.darkText : .secondary)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    Text(item.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Group {
                    if isSelected {
                        LiquidGlassBackground(radius: 8, showsSheen: true, bevelWidth: 1.0, hasShadow: false)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    }
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 设置子面板详情

struct NetworkSettingsDetailView: View {
    @ObservedObject var model: ManagerModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroBanner

                LazyVStack(spacing: 18) {
                    coreStatusCard
                    trafficProxyCard
                    protocolSupportCard
                }
            }
            .padding(24)
        }
    }

    private var heroBanner: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(MetallicTheme.prominentGradient)
                            .frame(width: 64, height: 64)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(MetallicTheme.metallicRimBorder, lineWidth: 1.0)
                            )
                        Image(systemName: "network")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(MetallicTheme.darkText)
                    }
                    .shadow(color: Color.black.opacity(0.2), radius: 8, y: 4)

                    Circle()
                        .fill(Color.green)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
                        .offset(x: 3, y: 3)
                        .shadow(color: Color.green.opacity(0.6), radius: 5)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("网络与代理核心")
                            .font(.system(size: 22, weight: .bold))
                            .lineLimit(1)

                        Text("内核就绪")
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .foregroundStyle(Color.green)
                            .background(Capsule().fill(Color.green.opacity(0.12)))
                            .overlay(Capsule().strokeBorder(Color.green.opacity(0.3), lineWidth: 0.7))
                    }

                    Text("由独立 sing-box 进程提供精准协议转发与防泄露机制 · 隔离各环境流量")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 16)

                LiquidGlassButton(
                    title: "刷新节点",
                    systemImage: "arrow.clockwise",
                    variant: .regular,
                    size: .small
                ) {
                    for sub in model.subscriptions {
                        model.refresh(sub)
                    }
                }
            }

            Divider().opacity(0.3)

            HStack(spacing: 12) {
                Label("内置 sing-box 进程运行正常 · 独占回环套接字端口", systemImage: "checkmark.shield.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.green)

                Spacer()

                Text("\(model.subscriptions.count) 个订阅 · \(model.proxies.count) 个独立代理")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .background(
            LiquidGlassBackground(radius: 18, interactive: true, showsSheen: true)
        )
    }

    private var coreStatusCard: some View {
        LiquidGlassCard(title: "内核引擎状态", systemImage: "bolt.horizontal.circle") {
            VStack(alignment: .leading, spacing: 12) {
                settingsRow(
                    icon: "cpu",
                    title: "内置 sing-box 核心",
                    subtitle: "独立后台守护运行，支持精准协议分流与零 DNS 泄露",
                    trailing: HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("就绪").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
                    }
                )

                Divider().opacity(0.2)

                settingsRow(
                    icon: "arrow.triangle.swap",
                    title: "流量接管模式",
                    subtitle: "基于专用回环端口与每个环境独立沙盒绑定的代理路由",
                    trailing: Text("按环境多路隔离").font(.system(size: 11.5)).foregroundStyle(.secondary)
                )

                Divider().opacity(0.2)

                settingsRow(
                    icon: "shield.checkerboard",
                    title: "防 DNS 污染与穿透",
                    subtitle: "环境内部所有域名解析经由代理节点远端安全解析",
                    trailing: Text("全时开启").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.green)
                )
            }
        }
    }

    private var trafficProxyCard: some View {
        LiquidGlassCard(title: "代理统计与分流", systemImage: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 12) {
                settingsRow(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "已加载订阅源",
                    subtitle: "支持标准 Clash / Base64 格式订阅配置自动解析与周期刷新",
                    trailing: Text("\(model.subscriptions.count) 个订阅").font(.system(size: 12, weight: .semibold))
                )

                Divider().opacity(0.2)

                settingsRow(
                    icon: "network",
                    title: "独立代理节点",
                    subtitle: "支持单个手动节点录入及环境独占代理分配",
                    trailing: Text("\(model.proxies.count) 个节点").font(.system(size: 12, weight: .semibold))
                )
            }
        }
    }

    private var protocolSupportCard: some View {
        LiquidGlassCard(title: "支持的协议规范", systemImage: "doc.text.magnifyingglass") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Safarier 内置核心原生支持以下主流代理传输协议：")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    protocolChip("Shadowsocks")
                    protocolChip("VMess")
                    protocolChip("VLESS")
                    protocolChip("Trojan")
                    protocolChip("Hysteria 2")
                    protocolChip("SOCKS5")
                    protocolChip("HTTP(S)")
                }
            }
        }
    }

    private func protocolChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7)
                    )
            )
    }

    private func settingsRow<T: View>(icon: String, title: String, subtitle: String, trailing: T) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 32, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
                    )
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(MetallicTheme.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            trailing
        }
    }
}

struct PrivacySettingsDetailView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroBanner

                LazyVStack(spacing: 18) {
                    featurePerturbationCard
                    systemIsolationCard
                    securityRulesCard
                }
            }
            .padding(24)
        }
    }

    private var heroBanner: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(MetallicTheme.prominentGradient)
                            .frame(width: 64, height: 64)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(MetallicTheme.metallicRimBorder, lineWidth: 1.0)
                            )
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(MetallicTheme.darkText)
                    }
                    .shadow(color: Color.black.opacity(0.2), radius: 8, y: 4)

                    Circle()
                        .fill(Color.green)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
                        .offset(x: 3, y: 3)
                        .shadow(color: Color.green.opacity(0.6), radius: 5)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("隐私与原生指纹防护")
                            .font(.system(size: 22, weight: .bold))
                            .lineLimit(1)

                        Text("内核级防护")
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .foregroundStyle(Color.green)
                            .background(Capsule().fill(Color.green.opacity(0.12)))
                            .overlay(Capsule().strokeBorder(Color.green.opacity(0.3), lineWidth: 0.7))
                    }

                    Text("基于 Safari 原生 WebKit 内核级防追踪能力 · 零外置注入脚本 · 杜绝设备跨站特征识别")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 16)
            }

            Divider().opacity(0.3)

            HStack(spacing: 12) {
                Label("沙盒会话特征加噪与硬件隔离保护已全面生效", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.green)

                Spacer()

                Text("Safari WebKit 原生内核")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .background(
            LiquidGlassBackground(radius: 18, interactive: true, showsSheen: true)
        )
    }

    private var featurePerturbationCard: some View {
        LiquidGlassCard(title: "会话级特征扰动", systemImage: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 14) {
                privacyFeatureRow(
                    title: "Canvas 与 WebGL 渲染加噪",
                    desc: "基于原生接口底层微小噪声注入，破坏跨站点设备 Canvas 绘图指纹哈希计算，同时保证界面肉眼渲染无失真。"
                )

                Divider().opacity(0.2)

                privacyFeatureRow(
                    title: "音频 API (AudioContext) 采样扰动",
                    desc: "针对 Web Audio API 振荡器与频域采样进行动态微扰，防御基于音频硬件特征的高精度跨站追踪。"
                )

                Divider().opacity(0.2)

                privacyFeatureRow(
                    title: "视口与分辨率隔离伪装",
                    desc: "独立暴露环境设定的屏幕分辨率与可用宽高参数，避免暴露宿主机的真实多屏与物理分辨率特征。"
                )
            }
        }
    }

    private var systemIsolationCard: some View {
        LiquidGlassCard(title: "系统级环境隔离", systemImage: "lock.shield.fill") {
            VStack(alignment: .leading, spacing: 14) {
                privacyFeatureRow(
                    title: "WebRTC 穿透阻断",
                    desc: "严格禁用页面 RTCPeerConnection 直连通道，杜绝通过 STUN/TURN 协议绕过代理泄露本机真实局域网与公网 IP。"
                )

                Divider().opacity(0.2)

                privacyFeatureRow(
                    title: "时区与语言深度同步",
                    desc: "网页主线程与 Web Worker 的 JavaScript 时区及客户端格式化严格映射为当前环境所配置的节点时区。"
                )

                Divider().opacity(0.2)

                privacyFeatureRow(
                    title: "系统字体暴露收窄",
                    desc: "隐藏宿主机安装的个性化中日韩第三方字体列表，仅对外暴露当前语言环境的标准系统字体白名单。"
                )
            }
        }
    }

    private var securityRulesCard: some View {
        LiquidGlassCard(title: "沙盒数据与安全规范", systemImage: "folder.badge.gearshape") {
            VStack(alignment: .leading, spacing: 10) {
                Text("每个沙盒环境均拥有独立的 Cookie、IndexedDB、LocalStorage 与 Web 缓存目录，互不交叉。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("环境删除或清空数据时，底层目录将被物理彻底粉碎，不残留任何历史标识符。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func privacyFeatureRow(title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(MetallicTheme.accent)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(desc)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
        }
    }
}

struct AboutSettingsDetailView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroBanner

                LazyVStack(spacing: 18) {
                    architectureCard
                    specificationsCard
                }
            }
            .padding(24)
        }
    }

    private var heroBanner: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(MetallicTheme.prominentGradient)
                        .frame(width: 64, height: 64)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(MetallicTheme.metallicRimBorder, lineWidth: 1.0)
                        )
                    Image(systemName: "safari.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(MetallicTheme.darkText)
                }
                .shadow(color: Color.black.opacity(0.2), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Safarier AI")
                            .font(.system(size: 22, weight: .bold))
                            .lineLimit(1)

                        Text("v1.0.1")
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .foregroundStyle(Color.primary)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.7))
                    }

                    Text("专为自动化与多环境沙盒设计的原生 WebKit 隐私浏览器")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 16)
            }

            Divider().opacity(0.3)

            HStack(spacing: 12) {
                Label("Universal (Apple Silicon & Intel) · macOS 13.0+", systemImage: "apple.logo")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("© 2026 Safarier")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(22)
        .background(
            LiquidGlassBackground(radius: 18, interactive: true, showsSheen: true)
        )
    }

    private var architectureCard: some View {
        LiquidGlassCard(title: "核心架构与技术栈", systemImage: "cpu") {
            VStack(alignment: .leading, spacing: 12) {
                techRow(title: "浏览器核心", value: "Apple WebKit 原生引擎 (高能效、原生系统渲染与极低显存占用)")
                Divider().opacity(0.2)
                techRow(title: "智能体工作台", value: "DeepSeek Harness (dsh) 原生沙盒受控独立运行时")
                Divider().opacity(0.2)
                techRow(title: "视觉模型辅助", value: "JEV 多模态视觉模型 (用于自动化界面的视觉辅助识别与精确定位)")
                Divider().opacity(0.2)
                techRow(title: "协议分流核心", value: "sing-box 独立进程与安全回环套接字路由")
            }
        }
    }

    private var specificationsCard: some View {
        LiquidGlassCard(title: "平台规范与数据安全", systemImage: "externaldrive.badge.checkmark") {
            VStack(alignment: .leading, spacing: 12) {
                techRow(title: "环境数据存储", value: "~/Library/Application Support/Safarier/Profiles/ (POSIX 0700 严格权限)")
                Divider().opacity(0.2)
                techRow(title: "DSH 受控挂载", value: "基于只读 DMG 严格签名校验挂载，退出时自动清理释放")
                Divider().opacity(0.2)
                techRow(title: "模型配置与凭据", value: "~/.config/mcc/models.toml (POSIX 0600 本地加密共享)")
            }
        }
    }

    private func techRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)

            Spacer()
        }
    }
}

// MARK: - 占位引导视图

struct ProfilesPlaceholderView: View {
    @ObservedObject var model: ManagerModel

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 90, height: 90)
                    .overlay(Circle().stroke(MetallicTheme.metallicRimBorder, lineWidth: 1.0))
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(MetallicTheme.specularLight)
            }

            VStack(spacing: 6) {
                Text(model.profiles.isEmpty ? "还没有环境" : "请选择一个环境")
                    .font(.system(size: 20, weight: .bold))
                Text(model.profiles.isEmpty ? "点击下方按钮创建第一个隔离沙盒环境" : "从左侧列表中点选环境即可查看配置详情与快速启动")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if model.profiles.isEmpty {
                LiquidGlassButton(title: "新建第一个环境", systemImage: "plus", variant: .prominent, size: .large) {
                    model.sheet = .newProfile
                }
            }
        }
        .padding(36)
        .background(LiquidGlassBackground(radius: 20))
        .padding(40)
    }
}

struct SubscriptionsPlaceholderView: View {
    @ObservedObject var model: ManagerModel

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 90, height: 90)
                    .overlay(Circle().stroke(MetallicTheme.metallicRimBorder, lineWidth: 1.0))
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 38))
                    .foregroundStyle(MetallicTheme.specularLight)
            }

            VStack(spacing: 6) {
                Text(model.subscriptions.isEmpty ? "还没有订阅" : "请选择一个订阅")
                    .font(.system(size: 20, weight: .bold))
                Text(model.subscriptions.isEmpty ? "点击下方按钮添加节点订阅链接或直接粘贴节点" : "从左侧列表中点选订阅即可查看包含的代理节点列表")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if model.subscriptions.isEmpty {
                LiquidGlassButton(title: "添加第一个订阅", systemImage: "plus", variant: .prominent, size: .large) {
                    model.sheet = .newSubscription
                }
            }
        }
        .padding(36)
        .background(LiquidGlassBackground(radius: 20))
        .padding(40)
    }
}

// MARK: - 列表行组件

struct ProfileRow: View {
    let profile: Profile
    let proxy: ProxyBinding
    let state: RunState

    var body: some View {
        HStack(spacing: 11) {
            ZStack(alignment: .bottomTrailing) {
                ProfileAvatar(profile: profile, size: 34)
                if state != .stopped {
                    Circle()
                        .fill(state == .running ? Color.green : Color.orange)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                        .shadow(color: (state == .running ? Color.green : Color.orange).opacity(0.5), radius: 3)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    ModeBadge(mode: profile.mode)
                }

                HStack(spacing: 8) {
                    Label(DisplayText.proxyName(proxy), systemImage: proxySymbol)
                    Text("·").foregroundStyle(.quaternary)
                    Label(DisplayText.shortTimeZone(of: profile), systemImage: "clock")
                }
                .labelStyle(CompactLabelStyle())
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var proxySymbol: String {
        switch proxy {
        case .direct: return "arrow.up.right"
        case .proxy: return "network"
        case .node: return "antenna.radiowaves.left.and.right"
        case .missing, .missingNode: return "exclamationmark.triangle"
        }
    }
}

struct SubscriptionRow: View {
    let subscription: Subscription
    let refreshing: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MetallicTheme.darkText)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(MetallicTheme.prominentGradient)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(MetallicTheme.metallicRimBorder, lineWidth: 0.8)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(subscription.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("\(subscription.nodes.count) 个节点")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if refreshing {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 头像与微质感徽章

/// 名字首字母 + 与主按钮完全一致的浅灰金属光泽底板头像。
struct ProfileAvatar: View {
    let profile: Profile
    let size: CGFloat

    var body: some View {
        let radius = size * 0.28
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let innerInset = max(1.4, size * 0.035)
        let innerShape = RoundedRectangle(cornerRadius: max(2, radius - innerInset), style: .continuous)

        ZStack {
            // 外圈车削金属环底座
            shape
                .fill(MetallicTheme.prominentGradient)

            // 内层亮银铂金主面板 + 放射状拉丝光泽
            innerShape
                .fill(MetallicTheme.prominentGradient)
                .padding(innerInset)

            innerShape
                .fill(MetallicTheme.anisotropicSheen())
                .padding(innerInset)

            innerShape
                .strokeBorder(MetallicTheme.metallicInnerBevel, lineWidth: 0.7)
                .padding(innerInset)

            // 外层 CNC 金属高光描边
            shape
                .strokeBorder(
                    MetallicTheme.metallicRimBorder,
                    lineWidth: max(0.9, size * 0.022)
                )

            // 首字母 (深钛黑文字，带微白高光，呈现物理蚀刻质感)
            Text(profile.name.first.map { String($0).uppercased() } ?? "?")
                .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                .foregroundStyle(MetallicTheme.darkText)
                .shadow(color: Color.white.opacity(0.65), radius: 0, x: 0, y: 0.8)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(red: 0xDC / 255.0, green: 0xEA / 255.0, blue: 0xFF / 255.0).opacity(0.14), radius: size * 0.08)
        .shadow(color: Color.black.opacity(0.32), radius: size * 0.12, y: size * 0.05)
    }
}

struct ModeBadge: View {
    let mode: ProfileMode
    var large = false

    var body: some View {
        let isPersistent = mode == .persistent
        let text = isPersistent ? (large ? "持久沙盒" : "持久") : (large ? "无痕沙盒" : "无痕")
        let accentColor = isPersistent ? MetallicTheme.accent : Color(red: 0x90 / 255.0, green: 0x9A / 255.0, blue: 0xAA / 255.0)

        Text(text)
            .font(large ? .system(size: 11.5, weight: .semibold) : .system(size: 10, weight: .semibold))
            .padding(.horizontal, large ? 8 : 5)
            .padding(.vertical, large ? 3 : 1.5)
            .foregroundStyle(accentColor)
            .background(
                Capsule()
                    .fill(accentColor.opacity(isPersistent ? 0.12 : 0.08))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.7), location: 0.0),
                                .init(color: accentColor.opacity(0.4), location: 0.5),
                                .init(color: Color.clear, location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.7
                    )
            )
    }
}

struct RunStateDot: View {
    let state: RunState

    var body: some View {
        switch state {
        case .stopped:
            EmptyView()
        case .starting:
            Circle().fill(.orange).frame(width: 8, height: 8).help("正在启动")
        case .running:
            Circle().fill(.green).frame(width: 8, height: 8).help("运行中")
        }
    }
}

struct ProtocolBadge: View {
    let type: SubscriptionNodeType

    var body: some View {
        let color = DisplayText.nodeColor(type)
        Text(DisplayText.nodeType(type))
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.6), location: 0.0),
                                .init(color: color.opacity(0.3), location: 0.5),
                                .init(color: Color.clear, location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.6
                    )
            )
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}
