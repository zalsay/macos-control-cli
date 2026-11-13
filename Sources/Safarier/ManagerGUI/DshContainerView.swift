import AppKit
import SwiftUI
import WebKit

/// DeepSeek Harness (dsh) Web 控制台容器。
/// 嵌在 Safarier Manager 详情区中，提供原生 WebKit 内核无缝渲染与服务生命周期控制。
struct DshContainerView: View {
    @ObservedObject private var service = DshService.shared
    @State private var webView: WKWebView?
    @State private var showLogs = false

    var body: some View {
        ZStack {
            switch service.status {
            case .running(let url):
                DshWebViewRepresentable(url: url, webView: $webView)
                    .ignoresSafeArea(.all)

            case .starting:
                startingView

            case .failed(let message):
                failedView(message)

            case .stopped:
                stoppedView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .dshReloadWeb)) { _ in
            (webView ?? service.cachedWebView)?.reload()
        }
        .onAppear {
            if service.status == .stopped {
                service.start()
            }
        }
    }

    // MARK: - 状态子视图

    private var startingView: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.regular)

            VStack(spacing: 6) {
                Text("正在启动 DeepSeek Harness (dsh) 服务…")
                    .font(.system(size: 14, weight: .semibold))
                Text("正在分配空闲端口并加载智能体 Web 界面，通常需要 1 ~ 3 秒。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !service.logs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("实时启动输出")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    ScrollView {
                        Text(service.logs.joined())
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 100)
                    .padding(8)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .frame(maxWidth: 480)
            }
        }
        .padding(32)
        .background(LiquidGlassBackground(radius: 16))
        .padding(32)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            VStack(spacing: 6) {
                Text("DeepSeek Harness 服务启动失败")
                    .font(.system(size: 15, weight: .bold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            HStack(spacing: 12) {
                LiquidGlassButton(
                    title: "重新启动",
                    systemImage: "arrow.clockwise",
                    variant: .prominent,
                    size: .regular
                ) {
                    service.restart()
                }

                #if !(SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE)
                Button("检查 dsh 安装") {
                    _ = service.locateBinary()
                }
                .buttonStyle(.borderless)
                #endif
            }

            if !service.logs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近错误日志：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(service.logs.suffix(20).joined())
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 90)
                    .padding(8)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .frame(maxWidth: 500)
            }
        }
        .padding(32)
        .background(LiquidGlassBackground(radius: 16))
        .padding(32)
    }

    private var stoppedView: some View {
        VStack(spacing: 20) {
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

            VStack(spacing: 6) {
                Text("DeepSeek Harness 智能体工作台")
                    .font(.system(size: 16, weight: .bold))
                Text("由 DeepSeek AI 开源的智能体框架，在 Manager 内部无缝运行 Web 控制台。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            LiquidGlassButton(
                title: "启动工作台",
                systemImage: "play.fill",
                variant: .prominent,
                size: .large
            ) {
                service.start()
            }
        }
        .padding(36)
        .background(LiquidGlassBackground(radius: 18))
        .padding(32)
    }
}

// MARK: - WKWebView NSViewRepresentable 桥接

struct DshWebViewRepresentable: NSViewRepresentable {
    let url: URL
    @Binding var webView: WKWebView?

    func makeNSView(context: Context) -> WKWebView {
        let wv = DshService.shared.getOrCreateWebView(for: url)
        DispatchQueue.main.async {
            self.webView = wv
        }
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url == nil || (nsView.url?.host != url.host || nsView.url?.port != url.port) {
            nsView.load(URLRequest(url: url))
        }
    }
}
