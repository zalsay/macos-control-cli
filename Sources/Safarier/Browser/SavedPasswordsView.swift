import AppKit
import SwiftUI
import SafarierCore

/// 浏览器的已保存密码管理面板（Liquid Glass 风格）。
struct SavedPasswordsView: View {
    let profileName: String
    let isEphemeral: Bool
    let store: WebCredentialStore
    let onDismiss: () -> Void

    @State private var credentials: [WebCredential] = []
    @State private var query = ""
    @State private var revealedIDs: Set<UUID> = []
    @State private var copiedText: String?

    private var filtered: [WebCredential] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return credentials }
        return credentials.filter {
            $0.domain.contains(text) || $0.username.lowercased().contains(text)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.88, green: 0.68, blue: 0.28).opacity(0.18))
                        .frame(width: 32, height: 32)
                    Image(systemName: "key.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0.88, green: 0.68, blue: 0.28))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("已保存密码")
                            .font(.system(size: 15, weight: .bold))
                        if isEphemeral {
                            Text("无痕模式·会话结束后清除")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.14)))
                        }
                    }
                    Text("环境「\(profileName)」· 共 \(credentials.count) 个网站凭据")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let copied = copiedText {
                    Text(copied)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }

                Button("关闭") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 0.7))
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))

            Divider()

            // 搜索框
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("搜索网站域名或用户名…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
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
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.7))
            )
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            Divider()

            // 凭据列表
            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: query.isEmpty ? "key.slash" : "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(query.isEmpty ? "暂无存储的网站密码" : "没有找到匹配的凭据")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("在网站登录并提交表单时，浏览器会自动提示保存")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 40)
            } else {
                List {
                    ForEach(filtered) { cred in
                        credentialRow(cred)
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 540, minHeight: 400)
        .onAppear {
            reload()
        }
    }

    private func reload() {
        credentials = store.all()
    }

    private func credentialRow(_ cred: WebCredential) -> some View {
        let isRevealed = revealedIDs.contains(cred.id)

        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 36, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.6))
                Image(systemName: "globe")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(red: 0.88, green: 0.68, blue: 0.28))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(cred.domain)
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    Text(cred.username.isEmpty ? "（空用户名）" : cred.username)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Button {
                        copy(text: cred.username, label: "已拷贝账号 ✓")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("拷贝用户名")
                }
            }

            Spacer()

            // 密码区域：•••••••• 或明文显示 + 眼睛切换
            HStack(spacing: 8) {
                if isRevealed {
                    Text(cred.password)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                } else {
                    Text("••••••••••••")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Button {
                    if isRevealed {
                        revealedIDs.remove(cred.id)
                    } else {
                        revealedIDs.insert(cred.id)
                    }
                } label: {
                    Image(systemName: isRevealed ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help(isRevealed ? "隐藏密码" : "显示密码")

                Button {
                    copy(text: cred.password, label: "已拷贝密码 ✓")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("拷贝密码")

                Button {
                    delete(cred)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.8))
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("删除此密码")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
        }
        .padding(.vertical, 4)
    }

    private func copy(text: String, label: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        withAnimation { copiedText = label }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copiedText = nil }
        }
    }

    private func delete(_ cred: WebCredential) {
        try? store.remove(id: cred.id)
        withAnimation {
            reload()
        }
    }
}
