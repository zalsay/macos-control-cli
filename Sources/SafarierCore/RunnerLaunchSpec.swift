import Foundation

/// Manager 启动 Runner 进程时的参数协议。Manager 用 `arguments()`/`environment(inheriting:)` 生成，
/// Runner 用 `parse(_:)` 还原。语言和时区放在进程级（`-AppleLanguages`、`TZ`），不靠页面脚本。
public struct RunnerLaunchSpec: Equatable, Sendable {
    public static let subcommand = "run"

    public var profileID: UUID
    public var startURL: URL?
    /// BCP-47 列表；非空时以 `-AppleLanguages` 传给 Runner 进程（NSArgumentDomain，公开行为）。
    public var languages: [String]
    /// IANA 时区；非空时以 `TZ` 环境变量传给 Runner 进程。M0-2 实测：TZ 不会传到 WebContent 进程，
    /// 网页时区要靠引擎层适配器；这里仍传 TZ，让 Runner 自身（日志、界面）与 profile 一致。
    public var timeZoneIdentifier: String?
    /// 探针模式：不显示窗口，加载页面后把能力报告和页面观测值以 JSON 打到 stdout 再退出。
    public var probe: Bool
    public var backgroundAutomation: Bool
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    /// Requests only the private registration transport, never control authority.
    public var registeredInteractive = false
    /// Presentation hint only; does not grant registration or control authority.
    public var nonActivatingPresentation = false
    #endif
    /// 只对这一次运行覆盖 profile.spi（例如探针做开/关对比）；nil 表示沿用 profile 的设置。
    public var spiOverride: SPIFeatures?

    public init(
        profileID: UUID,
        startURL: URL? = nil,
        languages: [String] = [],
        timeZoneIdentifier: String? = nil,
        probe: Bool = false,
        spiOverride: SPIFeatures? = nil,
        backgroundAutomation: Bool = false
    ) {
        self.profileID = profileID
        self.startURL = startURL
        self.languages = languages
        self.timeZoneIdentifier = timeZoneIdentifier
        self.probe = probe
        self.backgroundAutomation = backgroundAutomation
        self.spiOverride = spiOverride
    }

    /// 不含可执行文件路径本身。
    public func arguments() -> [String] {
        var args = [Self.subcommand, "--profile", profileID.uuidString]
        if let startURL {
            args += ["--url", startURL.absoluteString]
        }
        if probe {
            args.append("--probe")
        }
        if backgroundAutomation { args.append("--background-automation") }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        if registeredInteractive { args.append("--registered-interactive") }
        if nonActivatingPresentation { args.append("--non-activating-presentation") }
        #endif
        if let spiOverride {
            args += ["--spi", spiOverride.description]
        }
        if !languages.isEmpty {
            args += ["-AppleLanguages", Self.plistArrayString(languages)]
        }
        return args
    }

    public func environment(inheriting base: [String: String]) -> [String: String] {
        // 父进程残留的跟随代理结果（SAFARIER_GEO_*）不能带进新的 Runner，否则会被当成「已经解析过」直接沿用。
        var env = base.filter { !$0.key.hasPrefix("SAFARIER_GEO_") }
        if let timeZoneIdentifier {
            env["TZ"] = timeZoneIdentifier
        } else {
            env.removeValue(forKey: "TZ")
        }
        return env
    }

    /// `arguments` 不含可执行文件路径，第一个元素应为 `run`。
    /// 允许夹杂 `-NSXxx`/`-AppleXxx <value>` 这类 NSUserDefaults 参数（Xcode、launchd 会追加）。
    public static func parse(_ arguments: [String], environment: [String: String] = [:]) throws -> RunnerLaunchSpec {
        guard arguments.first == subcommand else { throw RunnerLaunchSpecError.missingSubcommand }

        var profileID: UUID?
        var startURL: URL?
        var languages: [String] = []
        var probe = false
        var backgroundAutomation = false
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        var registeredInteractive = false
        var nonActivatingPresentation = false
        #endif
        var spiOverride: SPIFeatures?

        var index = 1
        func value(after flag: String) throws -> String {
            guard index + 1 < arguments.count else { throw RunnerLaunchSpecError.missingValue(flag) }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--profile":
                let raw = try value(after: arg)
                guard let id = UUID(uuidString: raw) else { throw RunnerLaunchSpecError.invalidProfileID(raw) }
                profileID = id
            case "--url":
                let raw = try value(after: arg)
                guard let url = URL(string: raw), url.scheme != nil else { throw RunnerLaunchSpecError.invalidURL(raw) }
                startURL = url
            case "--background-automation":
                backgroundAutomation = true
            #if SAFARIER_BOUND_LOCAL_CANDIDATE
            case "--registered-interactive":
                guard !registeredInteractive else { throw RunnerLaunchSpecError.incompatibleModes }
                registeredInteractive = true
            case "--non-activating-presentation":
                guard !nonActivatingPresentation else { throw RunnerLaunchSpecError.incompatibleModes }
                nonActivatingPresentation = true
            #endif
            case "--probe":
                probe = true
            case "--spi":
                let raw = try value(after: arg)
                do {
                    spiOverride = try SPIFeatures(parsing: raw)
                } catch {
                    throw RunnerLaunchSpecError.invalidSPI(raw)
                }
            case "-AppleLanguages":
                languages = parsePlistArrayString(try value(after: arg))
            default:
                if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
                    _ = try value(after: arg)
                } else {
                    throw RunnerLaunchSpecError.unknownArgument(arg)
                }
            }
            index += 1
        }

        guard let profileID else { throw RunnerLaunchSpecError.missingProfileID }
        guard !(probe && backgroundAutomation) else { throw RunnerLaunchSpecError.incompatibleModes }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        guard !registeredInteractive || (!probe && !backgroundAutomation) else { throw RunnerLaunchSpecError.incompatibleModes }
        guard !nonActivatingPresentation || (registeredInteractive && !probe && !backgroundAutomation) else { throw RunnerLaunchSpecError.incompatibleModes }
        #endif
        let tz = environment["TZ"].flatMap { $0.isEmpty ? nil : $0 }
        var spec = RunnerLaunchSpec(
            profileID: profileID,
            startURL: startURL,
            languages: languages,
            timeZoneIdentifier: tz,
            probe: probe,
            spiOverride: spiOverride,
            backgroundAutomation: backgroundAutomation
        )
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        spec.registeredInteractive = registeredInteractive
        spec.nonActivatingPresentation = nonActivatingPresentation
        #endif
        return spec
    }

    /// 去掉已有的 `-AppleLanguages <值>`，换成新的语言。语言跟随代理时 Runner 用它重新启动自己。
    public static func replacingAppleLanguages(_ languages: [String], in arguments: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "-AppleLanguages" {
                index += 2
                continue
            }
            out.append(arguments[index])
            index += 1
        }
        return out + ["-AppleLanguages", plistArrayString(languages)]
    }

    /// NSUserDefaults 参数域接受旧式 plist 数组：`("en-US", "en")`。
    static func plistArrayString(_ values: [String]) -> String {
        "(" + values.map { "\"\($0)\"" }.joined(separator: ", ") + ")"
    }

    static func parsePlistArrayString(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let array = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return [] }
        return array
    }
}

public enum RunnerLaunchSpecError: Error, Equatable {
    case incompatibleModes
    case missingSubcommand
    case missingProfileID
    case invalidProfileID(String)
    case invalidURL(String)
    case unknownArgument(String)
    case missingValue(String)
    case invalidSPI(String)
}
