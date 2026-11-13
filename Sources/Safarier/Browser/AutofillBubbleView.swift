import AppKit
import SwiftUI
import SafarierCore

/// 点击工具栏钥匙图标时弹出的网站账号密码自动填写菜单浮层。
struct AutofillBubbleView: View {
    let domain: String
    let credentials: [WebCredential]
    let onFill: (WebCredential) -> Void
    let onOpenManager: () -> Void

    @State private var copiedFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 头部标题
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.88, green: 0.68, blue: 0.28))
                Text("此网站的已存账号")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text(domain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Divider()

            if credentials.isEmpty {
                VStack(spacing: 6) {
                    Text("当前网站暂未存储账号密码")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("登录成功后将提示您自动保存")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(credentials) { cred in
                            accountRow(cred)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(maxHeight: 220)
            }

            Divider()

            // 底部操作：管理全部密码
            HStack {
                if let copied = copiedFeedback {
                    Text(copied)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Spacer()
                Button {
                    onOpenManager()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10.5))
                        Text("管理密码…")
                            .font(.system(size: 11.5))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .frame(width: 320)
        .background(VisualEffectBackground(material: .popover, blendingMode: .behindWindow))
    }

    private func accountRow(_ cred: WebCredential) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 28, height: 28)
                Image(systemName: "person.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.88, green: 0.68, blue: 0.28))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(cred.username.isEmpty ? "（未命名的账号）" : cred.username)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text("••••••••")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            // 拷贝密码按钮
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(cred.password, forType: .string)
                withAnimation { copiedFeedback = "已拷贝密码 ✓" }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { copiedFeedback = nil }
                }
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(5)
            }
            .buttonStyle(.plain)
            .help("拷贝密码")

            // 一键填写按钮
            Button {
                onFill(cred)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "pencil.and.outline")
                        .font(.system(size: 10, weight: .bold))
                    Text("填写")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.94, green: 0.82, blue: 0.52), Color(red: 0.84, green: 0.64, blue: 0.28)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                )
            }
            .buttonStyle(.plain)
            .help("自动填充此账号密码至表单")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        )
    }
}
