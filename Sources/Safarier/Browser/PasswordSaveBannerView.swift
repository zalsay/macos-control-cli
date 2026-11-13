import SwiftUI
import SafarierCore

/// 询问用户是否为此网站存储密码的浮层横幅 (Liquid Glass 风格，贴合浏览器顶部)。
struct PasswordSaveBannerView: View {
    let domain: String
    let username: String
    let password: String
    let onSave: () -> Void
    let onNotNow: () -> Void
    let onNever: () -> Void

    @State private var isSaved = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.88, green: 0.68, blue: 0.28).opacity(0.18))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Circle().stroke(Color(red: 0.88, green: 0.68, blue: 0.28).opacity(0.35), lineWidth: 0.8)
                    )
                Image(systemName: isSaved ? "checkmark" : "key.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isSaved ? Color.green : Color(red: 0.88, green: 0.68, blue: 0.28))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(isSaved ? "密码已成功保存" : "要为「\(domain)」保存此密码吗？")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                if !username.isEmpty {
                    Text("账号：\(username)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 16)

            if !isSaved {
                HStack(spacing: 8) {
                    Button("永不") {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            onNever()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                    Button("稍后") {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            onNotNow()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 0.6))
                    )

                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isSaved = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            onSave()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                            Text("存储密码")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(LinearGradient(
                                    colors: [Color(red: 0.94, green: 0.82, blue: 0.52), Color(red: 0.84, green: 0.64, blue: 0.28)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                                .shadow(color: Color.black.opacity(0.15), radius: 3, x: 0, y: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                .background(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.28), radius: 16, x: 0, y: 6)
        )
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        ))
    }
}
