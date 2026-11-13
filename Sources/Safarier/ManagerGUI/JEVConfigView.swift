import SwiftUI

/// JEV 视觉辅助模型配置视图：统一使用 Liquid Glass 英雄横幅与模块化玻璃质感卡片布局。
struct JEVConfigView: View {
    var embedded: Bool = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var snapshot: JEVConfigStore.Snapshot?
    @State private var enabled = true
    @State private var endpoint = ""
    @State private var model = ""
    @State private var key = ""
    @State private var error: String?
    @State private var savedSuccess = false
    private let store = JEVConfigStore(directory: JEVConfigStore.defaultDirectory)

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                VStack(spacing: 0) {
                    content
                    Divider().opacity(0.3)
                    HStack {
                        Spacer()
                        Button("关闭", role: .cancel) { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(16)
                    .background(Color.black.opacity(0.2))
                }
                .frame(width: 620, height: 680)
            }
        }
        .onAppear { load() }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroBanner

                LazyVStack(spacing: 18) {
                    runtimeCard
                    apiEndpointCard
                    privacyCard
                }
            }
            .padding(24)
        }
    }

    // MARK: - 顶部 Hero Banner

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
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(MetallicTheme.darkText)
                    }
                    .shadow(color: Color.black.opacity(0.2), radius: 8, y: 4)

                    Circle()
                        .fill(enabled ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
                        .offset(x: 3, y: 3)
                        .shadow(color: (enabled ? Color.green : Color.clear).opacity(0.6), radius: 5)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("JEV 视觉模型")
                            .font(.system(size: 22, weight: .bold))
                            .lineLimit(1)

                        Text(enabled ? "已启用" : "未启用")
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .foregroundStyle(enabled ? Color.green : Color.secondary)
                            .background(
                                Capsule()
                                    .fill((enabled ? Color.green : Color.secondary).opacity(0.12))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder((enabled ? Color.green : Color.secondary).opacity(0.3), lineWidth: 0.7)
                            )
                    }

                    Text("用于自动化界面的视觉辅助识别与定位 · 配置文件与 MCC 实时共享")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 16)

                LiquidGlassButton(
                    title: "保存配置",
                    systemImage: "checkmark",
                    variant: .prominent,
                    size: .small
                ) {
                    save()
                }
                .disabled(snapshot == nil)
            }

            Divider().opacity(0.3)

            HStack(spacing: 12) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                } else if savedSuccess {
                    Label("配置已成功保存并即时生效", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 11.5, weight: .medium))
                } else {
                    Label("修改配置将即时同步至本地 ~/.config/mcc/models.toml", systemImage: "info.circle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if let snapshot {
                    Text(snapshot.hasKey ? "密钥已设置" : "未配置密钥")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(snapshot.hasKey ? Color.secondary : Color.orange)
                }
            }
        }
        .padding(22)
        .background(
            LiquidGlassBackground(radius: 18, interactive: true, showsSheen: true)
        )
    }

    // MARK: - 卡片 1：运行参数

    private var runtimeCard: some View {
        LiquidGlassCard(title: "运行参数", systemImage: "gearshape.2") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("启用 JEV 视觉辅助定位")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("在网页复杂动态元素或无唯一 DOM 属性时，通过视觉模型截图切片辅助定位目标坐标")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Divider().opacity(0.2)

                VStack(alignment: .leading, spacing: 6) {
                    Text("模型标识 (Model Name)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("例如 gpt-4o-mini 或 gemini-2.5-flash", text: $model)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.25))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
                                )
                        )
                }
            }
        }
    }

    // MARK: - 卡片 2：接口与鉴权

    private var apiEndpointCard: some View {
        LiquidGlassCard(title: "接口与鉴权", systemImage: "key.horizontal") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("HTTPS API 端点 (Endpoint)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("https://api.openai.com/v1 或兼容端点", text: $endpoint)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.25))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
                                )
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("API 密钥 (API Key)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if snapshot?.hasKey == true {
                            Text("已保存现有密钥")
                                .font(.system(size: 11))
                                .foregroundStyle(MetallicTheme.accent)
                        }
                    }

                    SecureField(snapshot?.hasKey == true ? "输入新密钥以覆盖，留空保留原有密钥" : "请输入 API 密钥", text: $key)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.25))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
                                )
                        )
                }
            }
        }
    }

    // MARK: - 卡片 3：隐私与数据安全说明

    private var privacyCard: some View {
        LiquidGlassCard(title: "隐私与数据说明", systemImage: "lock.shield") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(MetallicTheme.accent)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("局部目标切片传输")
                            .font(.system(size: 13, weight: .semibold))
                        Text("仅传输待识别元素与周围参考上下文微缩切片，绝不上传完整屏幕截图。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider().opacity(0.15)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "doc.badge.gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(MetallicTheme.accent)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("与 MCC 本地安全共享")
                            .font(.system(size: 13, weight: .semibold))
                        Text("配置文件以 0600 POSIX 权限保存在本地 ~/.config/mcc/models.toml，修改后跨进程即时生效。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 存储逻辑

    private func load() {
        do {
            let value = try store.read()
            snapshot = value
            enabled = value.enabled
            endpoint = value.endpoint
            model = value.model
        } catch {
            self.error = message(error)
        }
    }

    private func save() {
        guard let snapshot else { return }
        do {
            try store.save(snapshot, enabled: enabled, endpoint: endpoint, model: model, newKey: key)
            key = ""
            if embedded {
                savedSuccess = true
                error = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    savedSuccess = false
                }
            } else {
                dismiss()
            }
        } catch {
            self.error = message(error)
            savedSuccess = false
        }
    }

    private func message(_ error: Error) -> String {
        switch error as? JEVConfigStore.Failure {
        case .unsupported: return "配置格式不受支持，未修改。请先使用 MCC 检查配置。"
        case .changed: return "配置在打开后发生变化，请取消并重新打开后再保存。"
        case .busy: return "MCC 配置正在写入或锁文件存在，请稍后检查。"
        case .invalid: return "请填写有效 HTTPS 地址、模型名和 API 密钥。"
        case .committedUnconfirmed: return "配置可能已写入但磁盘同步未确认，请取消并重新打开核对。"
        default: return "无法安全读取或保存配置，请检查路径、所有权和权限。"
        }
    }
}
