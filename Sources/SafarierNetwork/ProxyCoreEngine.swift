import Foundation
import SafarierCore

/// 订阅节点由哪个代理内核运行：URI 节点用 sing-box；Clash 订阅用 mihomo（保留链式代理、证书指纹、XUDP 等原生语义）。
public enum ProxyCoreEngine: String, Sendable, Equatable, CaseIterable {
    case singbox
    case mihomo

    /// 可执行文件名，同时也是进程名（回收遗留进程时用来确认 pid 没有被别的程序复用）。
    public var executableName: String {
        switch self {
        case .singbox: return "sing-box"
        case .mihomo: return "mihomo"
        }
    }

    /// 错误信息里显示的名字。
    public var displayName: String { executableName }

    /// 指定可执行文件路径的环境变量。
    public var environmentVariable: String {
        switch self {
        case .singbox: return "SAFARIER_SINGBOX"
        case .mihomo: return "SAFARIER_MIHOMO"
        }
    }

    /// 找到的内核；一个都没有时是 Homebrew 的默认位置（启动时报 executableNotFound）。
    public var defaultExecutableURL: URL {
        locateExecutable() ?? URL(fileURLWithPath: fixedLocations[0])
    }

    /// 依次是环境变量指定的路径、App 自带的 `Contents/Helpers/<内核>`、Homebrew 的两个位置、PATH。
    /// 从访达启动的 App 拿不到 shell 的 PATH，所以先查固定位置。
    public func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledExecutable: URL? = nil
    ) -> URL? {
        if let override = environment[environmentVariable], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let bundled = bundledExecutable ?? bundledExecutableURL()
        let path = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(executableName)" }
        return ([bundled?.path].compactMap { $0 } + fixedLocations + path)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// `Contents/MacOS/...` 旁边的 `Contents/Helpers/<内核>`（scripts/build-app.sh 放进去的）。
    /// 不是从 .app 里运行（swift run、测试）时为 nil。
    public func bundledExecutableURL(mainExecutable: URL = RunnerLauncher.currentExecutableURL()) -> URL? {
        let macOS = mainExecutable.resolvingSymlinksInPath().deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents" else { return nil }
        let direct = contents.appendingPathComponent("Helpers/\(executableName)")
        if FileManager.default.isExecutableFile(atPath: direct.path) { return direct }
        // 若当前位于嵌套的 Helper App（如 Contents/Helpers/Safarier AI Browser.app），尝试上层主 App 的 Helpers 目录
        let parentHelpers = contents.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(executableName)
        if FileManager.default.isExecutableFile(atPath: parentHelpers.path) { return parentHelpers }
        return direct
    }

    /// 按文件名判断可执行文件属于哪个内核（错误信息用）。
    public static func matching(executableURL: URL) -> ProxyCoreEngine? {
        allCases.first { $0.executableName == executableURL.lastPathComponent }
    }

    /// 所有内核的进程名：回收遗留进程时用来确认 pid 确实是代理内核。
    static var knownExecutableNames: Set<String> { Set(allCases.map(\.executableName)) }

    /// 固定位置列表：Homebrew（Apple 芯片、Intel）。
    var fixedLocations: [String] {
        ["/opt/homebrew/bin/\(executableName)", "/usr/local/bin/\(executableName)"]
    }
}

public extension SubscriptionNode {
    /// 节点由哪个内核运行：带 mihomo 条目的是 mihomo，否则是 sing-box。
    var proxyEngine: ProxyCoreEngine { mihomoProxies == nil ? .singbox : .mihomo }
}
