import AppKit
import SwiftUI
import WebKit
import SafarierCore

/// 网站图标（Favicon）获取、Retina 渲染与多级缓存（内存 + 本地磁盘）服务
@MainActor
public final class FaviconService {
    public static let shared = FaviconService()
    public static let didUpdateFaviconNotification = Notification.Name("FaviconServiceDidUpdateFaviconNotification")

    private let memoryCache = NSCache<NSString, NSImage>()
    private var pendingTasks: [String: [(NSImage?) -> Void]] = [:]
    private let urlSession: URLSession

    private init() {
        memoryCache.countLimit = 600
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.requestCachePolicy = .returnCacheDataElseLoad
        self.urlSession = URLSession(configuration: config)
    }

    private var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Safarier/favicons", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func diskURL(for host: String) -> URL {
        let safeHost = host
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return cacheDirectory.appendingPathComponent("\(safeHost).png")
    }

    /// 同步返回缓存中的 Favicon（内存优先，次查本地磁盘）
    public func getFavicon(for url: URL?) -> NSImage? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        let key = host as NSString
        if let memoryImage = memoryCache.object(forKey: key) {
            return memoryImage
        }
        let file = diskURL(for: host)
        if FileManager.default.fileExists(atPath: file.path),
           let data = try? Data(contentsOf: file),
           let diskImage = NSImage(data: data) {
            let retina = Self.makeRetinaFavicon(from: diskImage) ?? diskImage
            memoryCache.setObject(retina, forKey: key)
            return retina
        }
        return nil
    }

    /// 异步获取 Favicon：未命中缓存时逐级尝试网络解析
    public func loadFavicon(for url: URL, explicitIconURL: URL? = nil, completion: (@escaping (NSImage?) -> Void)) {
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            completion(nil)
            return
        }

        if let cached = getFavicon(for: url) {
            completion(cached)
            return
        }

        if pendingTasks[host] != nil {
            pendingTasks[host]?.append(completion)
            return
        }
        pendingTasks[host] = [completion]

        Task {
            let image = await self.fetchFaviconAsync(pageURL: url, explicitIconURL: explicitIconURL)
            await MainActor.run {
                if let image {
                    self.saveToCache(image: image, host: host)
                }
                let callbacks = self.pendingTasks.removeValue(forKey: host) ?? []
                for callback in callbacks {
                    callback(image)
                }
                if image != nil {
                    NotificationCenter.default.post(
                        name: Self.didUpdateFaviconNotification,
                        object: self,
                        userInfo: ["host": host]
                    )
                }
            }
        }
    }

    /// 从页面 WKWebView 的 DOM 中提取 Favicon 链接并异步缓存
    public func extractFavicon(from webView: WKWebView, for pageURL: URL, completion: (@escaping (NSImage?) -> Void)) {
        guard let host = pageURL.host?.lowercased(), !host.isEmpty else {
            completion(nil)
            return
        }

        let js = """
        (() => {
            const selectors = [
                'link[rel="apple-touch-icon"]',
                'link[rel="apple-touch-icon-precomposed"]',
                'link[rel="icon"]',
                'link[rel="shortcut icon"]',
                'link[rel~="icon"]'
            ];
            for (const sel of selectors) {
                const el = document.querySelector(sel);
                if (el && el.href) return el.href;
            }
            return window.location.origin + '/favicon.ico';
        })()
        """

        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            var explicitURL: URL? = nil
            if let hrefString = result as? String {
                if hrefString.hasPrefix("data:image") {
                    if let data = Self.decodeDataURL(hrefString),
                       let image = NSImage(data: data),
                       let retina = Self.makeRetinaFavicon(from: image) {
                        self.saveToCache(image: retina, host: host)
                        completion(retina)
                        NotificationCenter.default.post(
                            name: Self.didUpdateFaviconNotification,
                            object: self,
                            userInfo: ["host": host]
                        )
                        return
                    }
                } else if let hrefURL = URL(string: hrefString) {
                    explicitURL = hrefURL
                }
            }

            self.loadFavicon(for: pageURL, explicitIconURL: explicitURL, completion: completion)
        }
    }

    private func saveToCache(image: NSImage, host: String) {
        let key = host as NSString
        memoryCache.setObject(image, forKey: key)

        let file = diskURL(for: host)
        Task.detached(priority: .background) {
            guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
                ?? (image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }) else { return }
            guard let pngData = rep.representation(using: .png, properties: [:]) else { return }
            try? pngData.write(to: file, options: .atomic)
        }
    }

    private func fetchFaviconAsync(pageURL: URL, explicitIconURL: URL?) async -> NSImage? {
        guard let host = pageURL.host?.lowercased(), !host.isEmpty else { return nil }

        var candidates: [URL] = []
        if let explicitIconURL {
            candidates.append(explicitIconURL)
        }
        let scheme = pageURL.scheme ?? "https"
        if let standard = URL(string: "\(scheme)://\(host)/favicon.ico"), !candidates.contains(standard) {
            candidates.append(standard)
        }
        if let ddg = URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico"), !candidates.contains(ddg) {
            candidates.append(ddg)
        }
        if let google = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64"), !candidates.contains(google) {
            candidates.append(google)
        }

        for candidate in candidates {
            if let img = await fetchSingleFavicon(from: candidate) {
                return img
            }
        }
        return nil
    }

    private func fetchSingleFavicon(from url: URL) async -> NSImage? {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 6
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            guard !data.isEmpty, let rawImage = NSImage(data: data) else {
                return nil
            }
            return Self.makeRetinaFavicon(from: rawImage)
        } catch {
            return nil
        }
    }

    /// 渲染为 16x16 pt（32x32 像素 Retina）高解析度图像
    public static func makeRetinaFavicon(from source: NSImage) -> NSImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 32 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        let graphicsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32), from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: 16, height: 16)
        let result = NSImage(size: NSSize(width: 16, height: 16))
        result.addRepresentation(rep)
        return result
    }

    private static func decodeDataURL(_ dataURLString: String) -> Data? {
        guard let commaIndex = dataURLString.firstIndex(of: ",") else { return nil }
        let meta = String(dataURLString[..<commaIndex])
        let payload = String(dataURLString[dataURLString.index(after: commaIndex)...])
        if meta.contains(";base64") {
            return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        } else if let decoded = payload.removingPercentEncoding {
            return Data(decoded.utf8)
        }
        return nil
    }
}

// MARK: - NSWindowTab 扩展：安全支持设置标签页 Favicon

extension NSWindowTab {
    @MainActor
    public func setFavicon(_ image: NSImage?) {
        if responds(to: NSSelectorFromString("setImage:")) {
            setValue(image, forKey: "image")
        }
        if responds(to: NSSelectorFromString("setShowIcon:")) {
            setValue(image != nil, forKey: "showIcon")
        }
    }
}

// MARK: - SwiftUI 网站图标视图组件

/// 显示指定 URL 的 Favicon 图标，带平滑加载与优雅 fallback (globe)
public struct FaviconImageView: View {
    let url: URL
    var size: CGFloat = 16
    @State private var image: NSImage?

    public init(url: URL, size: CGFloat = 16) {
        self.url = url
        self.size = size
    }

    public var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: max(2.5, size * 0.18), style: .continuous))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: size * 0.72))
                    .foregroundStyle(MetallicTheme.accent)
                    .frame(width: size, height: size)
            }
        }
        .onAppear { load() }
        .onChange(of: url) { _, _ in load() }
        .onReceive(NotificationCenter.default.publisher(for: FaviconService.didUpdateFaviconNotification)) { notif in
            if let host = notif.userInfo?["host"] as? String, host == url.host?.lowercased() {
                load()
            }
        }
    }

    private func load() {
        if let cached = FaviconService.shared.getFavicon(for: url) {
            self.image = cached
            return
        }
        FaviconService.shared.loadFavicon(for: url) { img in
            self.image = img
        }
    }
}
