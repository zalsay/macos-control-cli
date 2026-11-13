import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SafarierCore
import Yams

public enum SubscriptionParseError: Error, Equatable {
    case invalidLine(String)
    case invalidBase64
    case invalidJSON
    case invalidClashYAML
    case unsupportedClash([String: Int])
    case unsupportedScheme(String)
}

/// 解析结果：支持的节点，和因协议不支持而跳过的行（按协议名计数，如 `["hysteria2": 3]`）。
public struct SubscriptionParseResult: Equatable, Sendable {
    public var nodes: [SubscriptionNode]
    public var skippedSchemes: [String: Int]
    /// mihomo 会静默忽略、导入时明确提示的字段，按「协议.字段」计数（如 `["hysteria2.udp": 2]`）。这些节点仍然导入。
    public var ignoredFields: [String: Int]

    public init(nodes: [SubscriptionNode], skippedSchemes: [String: Int] = [:], ignoredFields: [String: Int] = [:]) {
        self.nodes = nodes
        self.skippedSchemes = skippedSchemes
        self.ignoredFields = ignoredFields
    }

    public var skippedCount: Int { skippedSchemes.values.reduce(0, +) }

    /// 有跳过的节点或被忽略的字段，导入时需要提示。
    public var hasNotices: Bool { skippedCount > 0 || !ignoredFields.isEmpty }
}

/// Parses common sing-box/Xray subscription formats into the shared node model.
public enum SubscriptionParser {
    public static func parse(_ data: Data) throws -> [SubscriptionNode] {
        guard let text = String(data: data, encoding: .utf8) else { throw SubscriptionParseError.invalidBase64 }
        return try parse(text)
    }

    public static func parse(_ content: String) throws -> [SubscriptionNode] {
        try parseResult(content).nodes
    }

    /// 机场订阅里常混着 hysteria2、tuic、ssr 等还不支持的协议：这些行跳过（计数），其它节点照常导入。
    /// 一个支持的节点都没有时才报第一个不支持的协议；支持的协议写错了（缺端口、密码等）仍然整份报错。
    public static func parseResult(_ content: String) throws -> SubscriptionParseResult {
        // 有些订阅（和 Windows 记事本存的文件）开头带 UTF-8 BOM，它不算空白，要单独去掉。
        let raw = stripBOM(content).trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = decodeBase64IfNeeded(raw)
        if looksLikeClash(decoded) { return try parseClash(decoded) }
        var lines: [String] = []
        for physicalLine in decoded.components(separatedBy: .newlines) {
            let line = physicalLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if !line.contains("://"), let previous = lines.last, previous.contains("://") {
                // 粘贴时折断的链接：续行里的缩进、空格不属于 Base64 内容。
                lines[lines.count - 1] += line.filter { !$0.isWhitespace }
            } else {
                lines.append(line)
            }
        }
        guard !lines.isEmpty else { return SubscriptionParseResult(nodes: []) }

        var nodes: [SubscriptionNode] = []
        var skipped: [String: Int] = [:]
        var firstUnsupported: SubscriptionParseError?
        for line in lines {
            do {
                nodes.append(try parseLine(line))
            } catch SubscriptionParseError.unsupportedScheme(let scheme) {
                skipped[scheme, default: 0] += 1
                firstUnsupported = firstUnsupported ?? .unsupportedScheme(scheme)
            } catch let error as SubscriptionParseError {
                throw error
            } catch {
                throw SubscriptionParseError.invalidLine(line)
            }
        }
        if nodes.isEmpty, let firstUnsupported { throw firstUnsupported }
        return SubscriptionParseResult(nodes: nodes, skippedSchemes: skipped)
    }

    private static func looksLikeClash(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            return value == "proxies:" || value.hasPrefix("proxies: ") || value == "---"
        }
    }

    /// Clash 订阅：每个代理条目原样保留（mihomo 后端要整段写进配置），同时整理出列表用的节点。
    /// 节点列表只是摘要，不再丢字段：证书指纹、XUDP、链式代理都留在保存的条目里。
    private static func parseClash(_ text: String) throws -> SubscriptionParseResult {
        let root: [String: Any]
        do { guard let object = try Yams.load(yaml: text) as? [String: Any] else { throw SubscriptionParseError.invalidClashYAML }; root = object }
        catch { throw SubscriptionParseError.invalidClashYAML }
        guard let entries = root["proxies"] as? [Any] else { throw SubscriptionParseError.invalidClashYAML }

        // 第一遍：按名字建索引（链式代理按 dialer-proxy 的名字找上游）。重名的后出现的条目不参与，名字在配置里保持唯一。
        var objects: [String: [String: Any]] = [:]
        var json: [String: JSONValue] = [:]
        var candidates: [(object: [String: Any], duplicate: Bool)] = []
        for entry in entries {
            guard let object = entry as? [String: Any], object["type"] is String else { throw SubscriptionParseError.invalidClashYAML }
            if let name = object["name"] as? String, !name.isEmpty {
                let duplicate = objects[name] != nil
                if !duplicate {
                    objects[name] = object
                    json[name] = try jsonValue(object)
                }
                candidates.append((object, duplicate))
            } else {
                candidates.append((object, false))
            }
        }

        var result = SubscriptionParseResult(nodes: [])
        let supported: [String: SubscriptionNodeType] = ["ss": .shadowsocks, "socks5": .socks, "vless": .vless, "vmess": .vmess, "trojan": .trojan, "anytls": .anytls, "hysteria2": .hysteria2]
        for (object, duplicate) in candidates {
            guard let rawType = object["type"] as? String else { throw SubscriptionParseError.invalidClashYAML }
            let type = rawType.lowercased()
            if duplicate { result.skippedSchemes["重名节点", default: 0] += 1; continue }
            guard let kind = supported[type] else {
                let safe = ["hysteria", "hy2", "tuic", "ssr", "http", "wireguard"].contains(type) ? type : "其他协议"
                result.skippedSchemes[safe, default: 0] += 1; continue
            }
            // mihomo 会忽略的字段：节点照常导入，但按字段名明确列出来（字段名是配置键，不含值）。
            for key in MihomoProxyFields.ignoredKeys(in: object, clashType: type) {
                result.ignoredFields["\(type).\(key)", default: 0] += 1
            }
            guard let name = object["name"] as? String, let server = object["server"] as? String,
                  let port = object["port"] as? Int, !(object["port"] is Bool) else { throw SubscriptionParseError.invalidClashYAML }
            // 链式代理的上游必须是订阅里的条目；缺失或成环时这个节点连不上，明确计数跳过，不让它进入配置。
            guard let chain = try proxyChain(from: name, objects: objects, json: json) else {
                result.skippedSchemes["\(type)（链式代理上游无效）", default: 0] += 1; continue
            }
            func string(_ key: String) -> String? { object[key] as? String }
            func bool(_ key: String) throws -> Bool {
                guard let value = object[key] else { return false }
                guard let value = value as? Bool else { throw SubscriptionParseError.invalidClashYAML }; return value
            }
            for key in ["uuid", "username", "password", "cipher", "servername", "sni", "flow", "network"] {
                if let value = object[key], !(value is String) { throw SubscriptionParseError.invalidClashYAML }
            }
            if let value = object["alterId"], (!(value is Int) || value is Bool) { throw SubscriptionParseError.invalidClashYAML }
            let insecure = try bool("skip-cert-verify")
            var parameters: [String: String] = [:]
            if insecure { parameters["allowInsecure"] = "true" }
            // hysteria2 只走 QUIC，列表里显示它的传输层。
            let transport = string("network") ?? (kind == .hysteria2 ? "quic" : nil)
            let node = SubscriptionNode(name: name, type: kind, server: server, serverPort: port,
                uuid: string("uuid"), username: string("username"), password: string("password"),
                method: string("cipher"), tls: try bool("tls") || kind == .trojan || kind == .anytls || kind == .hysteria2,
                serverName: string("servername") ?? string("sni"), transport: transport, flow: string("flow"),
                alterID: object["alterId"] as? Int, parameters: parameters, mihomoProxies: chain)
            do { try node.validate() } catch { throw SubscriptionParseError.invalidClashYAML }
            result.nodes.append(node)
        }
        if result.nodes.isEmpty {
            if !result.skippedSchemes.isEmpty { throw SubscriptionParseError.unsupportedClash(result.skippedSchemes) }
            throw SubscriptionParseError.invalidClashYAML
        }
        return result
    }

    /// 节点连接需要的条目：自己在前，然后沿 `dialer-proxy` 逐级找到的上游。上游缺失、名字为空或成环时返回 nil。
    private static func proxyChain(from name: String, objects: [String: [String: Any]], json: [String: JSONValue]) throws -> [JSONValue]? {
        var chain: [JSONValue] = []
        var visited: Set<String> = []
        var current = name
        while true {
            guard visited.insert(current).inserted, let object = objects[current], let entry = json[current] else { return nil }
            chain.append(entry)
            guard let upstream = object["dialer-proxy"] else { return chain }
            guard let upstreamName = upstream as? String else { throw SubscriptionParseError.invalidClashYAML }
            current = upstreamName
        }
    }

    /// Yams 解析出的值转成可保存的 JSON 值。遇到认不出的类型（日期、二进制）直接报错，不悄悄改写成字符串。
    private static func jsonValue(_ value: Any) throws -> JSONValue {
        switch value {
        case is NSNull: return .null
        case let value as Bool: return .bool(value)
        case let value as Int: return .int(value)
        case let value as Double: return .double(value)
        case let value as String: return .string(value)
        case let value as [Any]: return .array(try value.map { try jsonValue($0) })
        case let value as [String: Any]: return .object(try value.mapValues { try jsonValue($0) })
        default: throw SubscriptionParseError.invalidClashYAML
        }
    }

    /// Shadowsocks 链接的前缀（小写比较）。
    static let shadowsocksPrefixes = ["ss://", "ss2022://", "shadowsocks://"]
    static let socksPrefixes = ["socks://", "socks5://", "socks5h://"]

    public static func parseLine(_ line: String) throws -> SubscriptionNode {
        // 节点名在 `#` 后面，常带空格等 URL 里不允许的字符：先切掉，主体单独解析。
        let parts = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let body = String(parts[0])
        let name = parts.count > 1 ? decodedName(String(parts[1])) : nil
        // Shadowsocks 的密码（SS2022 是 Base64 密钥）常带 `/`、`+`、`=`，多用户 EIH 还带第二个 `:`，
        // 交给 URLComponents 会把 `/` 当成路径开头、把 `:` 后面当成 password，所以单独按字符串解析。
        let lowered = body.lowercased()
        if shadowsocksPrefixes.contains(where: lowered.hasPrefix) {
            return try parseShadowsocksURI(body, name: name)
        }
        if socksPrefixes.contains(where: lowered.hasPrefix) {
            return try parseSocksURI(body, name: name)
        }
        if let schemeRange = lowered.range(of: "://") {
            let rawScheme = String(lowered[..<schemeRange.lowerBound])
            let supported = ["vless", "vmess", "trojan", "anytls"]
            if !rawScheme.isEmpty, !supported.contains(rawScheme) {
                throw SubscriptionParseError.unsupportedScheme(rawScheme)
            }
        }
        // `://host` 这种没写协议的行：URL 会给出空的协议名，按写错了处理，不当成「不支持的协议」跳过。
        guard let url = URL(string: body), let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            throw SubscriptionParseError.invalidLine(line)
        }
        switch scheme {
        case "vless": return try parseVLESS(url, name: name)
        case "vmess": return try parseVMess(url, name: name)
        case "trojan": return try parseTrojan(url, name: name)
        case "anytls": return try parseAnyTLS(url, name: name)
        default: throw SubscriptionParseError.unsupportedScheme(scheme)
        }
    }

    private static func parseVLESS(_ url: URL, name: String?) throws -> SubscriptionNode {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = serverHost(components), let port = components.port,
              let uuid = components.user, !uuid.isEmpty else {
            throw SubscriptionParseError.invalidLine(url.absoluteString)
        }
        let query = queryValues(components)
        return SubscriptionNode(
            name: name ?? host,
            type: .vless,
            server: host,
            serverPort: port,
            // URLComponents.user 已经做过一次百分号解码，不要再解第二次（否则字面的 %41 会变成 A）。
            uuid: uuid,
            tls: tlsEnabled(query),
            serverName: nonEmpty(query["sni"]) ?? nonEmpty(query["serverName"]),
            transport: nonEmpty(query["type"]) ?? nonEmpty(query["network"]),
            transportPath: nonEmpty(query["path"]),
            transportHost: nonEmpty(query["host"]),
            flow: nonEmpty(query["flow"]),
            parameters: query
        )
    }

    private static func parseTrojan(_ url: URL, name: String?) throws -> SubscriptionNode {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = serverHost(components), let port = components.port,
              let user = components.user, !user.isEmpty else {
            throw SubscriptionParseError.invalidLine(url.absoluteString)
        }
        // 密码里有 `:` 时 URLComponents 会拆成 user 和 password，拼回去；两者都已解码过，不再解第二次。
        let password = components.password.map { "\(user):\($0)" } ?? user
        let query = queryValues(components)
        return SubscriptionNode(
            name: name ?? host,
            type: .trojan,
            server: host,
            serverPort: port,
            password: password,
            tls: true,
            serverName: nonEmpty(query["sni"]) ?? nonEmpty(query["peer"]),
            transport: nonEmpty(query["type"]) ?? nonEmpty(query["network"]),
            transportPath: nonEmpty(query["path"]),
            transportHost: nonEmpty(query["host"]),
            parameters: query
        )
    }

    /// Shadowsocks / Shadowsocks 2022 的各种链接写法（前缀 `ss://`、`ss2022://`、`shadowsocks://` 都认）：
    /// - SIP002 明文：`ss://method:password@host:port`（SS2022 密钥原样或百分号编码，多用户 EIH 是 `serverKey:userKey`）；
    /// - SIP002 Base64：`ss://BASE64(method:password)@host:port`；
    /// - 旧式整串 Base64：`ss://BASE64(method:password@host:port)`；
    /// - 可带 `/?plugin=...&uot=1` 查询参数，存进 `parameters`。
    static func parseShadowsocksURI(_ body: String, name: String?) throws -> SubscriptionNode {
        let invalid = SubscriptionParseError.invalidLine(body)
        guard let prefix = shadowsocksPrefixes.first(where: body.lowercased().hasPrefix) else { throw invalid }
        var authority = String(body.dropFirst(prefix.count))
        var parameters: [String: String] = [:]
        if let question = authority.firstIndex(of: "?") {
            parameters = queryValues(String(authority[authority.index(after: question)...]))
            authority = String(authority[..<question])
        }
        while authority.hasSuffix("/") { authority.removeLast() }
        if !authority.contains("@") {
            let token = authority.removingPercentEncoding ?? authority
            guard let data = decodeBase64(token), let text = String(data: data, encoding: .utf8) else { throw invalid }
            authority = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 密码里可能有 `@`：按最后一个 `@` 切。
        guard let at = authority.lastIndex(of: "@") else { throw invalid }
        let rawUserInfo = String(authority[..<at])
        guard let endpoint = hostAndPort(String(authority[authority.index(after: at)...])) else { throw invalid }
        let (host, port) = endpoint

        var userInfo = rawUserInfo.removingPercentEncoding ?? rawUserInfo
        if !userInfo.contains(":") {
            guard let data = decodeBase64(userInfo), let text = String(data: data, encoding: .utf8) else { throw invalid }
            userInfo = text
        }
        // 方法名里没有 `:`：按第一个 `:` 切，密码（含 EIH 的 `:` 和 Base64 的 `/`、`+`、`=`）原样保留。
        let split = userInfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard split.count == 2, !split[0].isEmpty, !split[1].isEmpty else { throw invalid }
        return SubscriptionNode(
            name: name ?? host,
            type: .shadowsocks,
            server: host,
            serverPort: port,
            password: normalizedShadowsocksPassword(split[1], method: split[0]),
            method: split[0],
            parameters: parameters
        )
    }

    /// SS2022（`2022-blake3-*`）的密钥是 Base64，sing-box 只认标准写法（`+`、`/`、带 `=` 补齐），
    /// 链接里常见的 URL-safe（`-`、`_`）或省略 `=` 的写法会报 `decode key: illegal base64 data`。
    /// 把每一段密钥（EIH 是 `serverKey:userKey`）解码再按标准 Base64 编回去；解不开的段原样保留（交给 sing-box 报错）。
    /// 其它加密方式的密码是普通字符串，不动。
    public static func normalizedShadowsocksPassword(_ password: String, method: String) -> String {
        guard method.lowercased().hasPrefix("2022-blake3-") else { return password }
        return password.split(separator: ":", omittingEmptySubsequences: false).map { part -> String in
            guard let data = decodeBase64(String(part)), !data.isEmpty else { return String(part) }
            return data.base64EncodedString()
        }.joined(separator: ":")
    }

    /// `host:port` 或 `[IPv6]:port`；IPv6 去掉方括号。
    private static func hostAndPort(_ value: String) -> (String, Int)? {
        let host: String, portText: Substring
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]"), value[value.index(after: close)...].hasPrefix(":") else { return nil }
            host = String(value[value.index(after: value.startIndex)..<close])
            portText = value[value.index(close, offsetBy: 2)...]
        } else {
            guard let colon = value.lastIndex(of: ":") else { return nil }
            host = String(value[..<colon])
            portText = value[value.index(after: colon)...]
        }
        guard !host.isEmpty, !host.contains(":") || value.hasPrefix("["),
              let port = Int(portText), (1...65535).contains(port) else { return nil }
        return (host, port)
    }

    /// `a=1&b=%3B`：值做百分号解码（不把 `+` 当空格，SIP002 的 plugin 参数用百分号编码）。
    /// 同一个 key 出现多次时取第一个，和其它协议（URLComponents）一致。
    private static func queryValues(_ query: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let key = kv[0].removingPercentEncoding, !key.isEmpty, kv.count == 2, out[key] == nil else { continue }
            out[key] = kv[1].removingPercentEncoding ?? kv[1]
        }
        return out
    }

    /// 支持明文、仅认证 Base64，以及 Shadowrocket 的整段 Base64。
    /// 不经 URLComponents，避免把 Base64 的 `/` 当路径、漏掉编码在内部的端口。
    static func parseSocksURI(_ body: String, name: String?) throws -> SubscriptionNode {
        let invalid = SubscriptionParseError.invalidLine(body)
        guard let prefix = socksPrefixes.first(where: body.lowercased().hasPrefix) else { throw invalid }
        var authority = String(body.dropFirst(prefix.count))
        var parameters: [String: String] = [:]
        if let question = authority.firstIndex(of: "?") {
            parameters = queryValues(String(authority[authority.index(after: question)...]))
            authority = String(authority[..<question])
        }
        var decodedAuthority = false
        if !authority.contains("@"), socksEndpoint(authority) == nil {
            let token = authority.removingPercentEncoding ?? authority
            guard let data = decodeBase64(token), let text = String(data: data, encoding: .utf8) else { throw invalid }
            authority = text.trimmingCharacters(in: .whitespacesAndNewlines)
            decodedAuthority = true
        }
        var username: String?
        var password: String?
        var endpointText = authority
        if let at = authority.lastIndex(of: "@") {
            endpointText = String(authority[authority.index(after: at)...])
            var userInfo = String(authority[..<at])
            var percentDecode = !decodedAuthority
            if !userInfo.contains(":"), !decodedAuthority {
                let token = userInfo.removingPercentEncoding ?? userInfo
                if let data = decodeBase64(token), let text = String(data: data, encoding: .utf8), text.contains(":") {
                    userInfo = text
                    percentDecode = false
                }
            }
            // 明文先按第一个冒号拆分，再分别解码；密码中的冒号和 @ 原样保留。
            // Base64 内的认证已经是原始文本，不能再把字面的 %41 等二次解释。
            let parts = userInfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let credentials = parts.map { percentDecode ? ($0.removingPercentEncoding ?? $0) : $0 }
            username = credentials[0].isEmpty ? nil : credentials[0]
            password = credentials.count > 1 && !credentials[1].isEmpty ? credentials[1] : nil
        }
        guard let (host, port) = socksEndpoint(endpointText) else { throw invalid }
        return SubscriptionNode(
            name: name ?? nonEmpty(parameters["remarks"]) ?? nonEmpty(parameters["remark"]) ?? host,
            type: .socks,
            server: host,
            serverPort: port,
            username: username,
            password: password,
            parameters: parameters
        )
    }

    private static func socksEndpoint(_ value: String) -> (String, Int)? {
        let endpoint = value.hasSuffix("/") ? String(value.dropLast()) : value
        guard let (host, port) = hostAndPort(endpoint),
              !host.contains(where: { $0.isWhitespace || "/@?#".contains($0) }) else { return nil }
        return (host, port)
    }

    /// `anytls://password@host:port?sni=example.com&insecure=1`。AnyTLS 总是走 TLS。
    private static func parseAnyTLS(_ url: URL, name: String?) throws -> SubscriptionNode {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = serverHost(components), let port = components.port,
              let user = components.user, !user.isEmpty else {
            throw SubscriptionParseError.invalidLine(url.absoluteString)
        }
        // 密码里有 `:` 时 URLComponents 会把它拆成 user 和 password，这里拼回去。
        let password = components.password.map { "\(user):\($0)" } ?? user
        let query = queryValues(components)
        return SubscriptionNode(
            name: name ?? host,
            type: .anytls,
            server: host,
            serverPort: port,
            password: password,
            tls: true,
            serverName: nonEmpty(query["sni"]) ?? nonEmpty(query["peer"]) ?? nonEmpty(query["serverName"]),
            parameters: query
        )
    }

    private static func parseVMess(_ url: URL, name fragmentName: String?) throws -> SubscriptionNode {
        let token = String(url.absoluteString.dropFirst("vmess://".count))
        guard let data = decodeBase64(token),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = (nonEmpty(object["add"] as? String) ?? nonEmpty(object["host"] as? String)).map(stripBrackets),
              let port = intValue(object["port"]),
              let uuid = (object["id"] as? String) ?? (object["uuid"] as? String) else {
            throw SubscriptionParseError.invalidJSON
        }
        let network = nonEmpty(object["net"] as? String) ?? nonEmpty(object["network"] as? String)
        let tls = ((object["tls"] as? String)?.lowercased() == "tls") || (object["tls"] as? Bool == true)
        let name = nonEmpty(object["ps"] as? String) ?? fragmentName ?? host
        return SubscriptionNode(
            name: name,
            type: .vmess,
            server: host,
            serverPort: port,
            uuid: uuid,
            method: object["scy"] as? String,
            tls: tls,
            serverName: nonEmpty(object["sni"] as? String) ?? nonEmpty(object["host"] as? String),
            transport: network,
            transportPath: nonEmpty(object["path"] as? String),
            transportHost: nonEmpty(object["host"] as? String),
            alterID: intValue(object["aid"]),
            parameters: object.reduce(into: [:]) { result, item in
                if let value = item.value as? String { result[item.key] = value }
            }
        )
    }

    /// 同一个 key 出现多次（`sni=a&sni=b`）时取第一个；`uniqueKeysWithValues` 遇到重复 key 会直接崩溃。
    private static func queryValues(_ components: URLComponents) -> [String: String] {
        Dictionary((components.queryItems ?? []).compactMap { item in
            guard let value = item.value else { return nil }
            return (item.name, value)
        }, uniquingKeysWith: { first, _ in first })
    }

    /// IPv6 主机在 URL 里带方括号（`[2001:db8::1]`），sing-box 要的是不带括号的地址。
    private static func serverHost(_ components: URLComponents) -> String? {
        guard let host = components.host, !host.isEmpty else { return nil }
        return stripBrackets(host)
    }

    private static func stripBrackets(_ host: String) -> String {
        host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }

    private static func tlsEnabled(_ query: [String: String]) -> Bool {
        let security = (query["security"] ?? query["tls"] ?? "").lowercased()
        return security == "tls" || security == "reality" || security == "1" || security == "true"
    }

    private static func decodedName(_ fragment: String) -> String? {
        let name = (fragment.removingPercentEncoding ?? fragment).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func decodeBase64IfNeeded(_ value: String) -> String {
        guard let data = decodeBase64(stripBOM(value)), let text = String(data: data, encoding: .utf8), text.contains("://") || looksLikeClash(text) else {
            return value
        }
        return stripBOM(text)
    }

    /// 去掉开头的 UTF-8 BOM（U+FEFF）。
    static func stripBOM(_ text: String) -> String {
        text.unicodeScalars.first == "\u{FEFF}" ? String(text.unicodeScalars.dropFirst()) : text
    }

    /// 去掉首尾空白后非空才返回：`sni=&serverName=a.example` 这种空参数不挡住后面的备用字段。
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    static func decodeBase64(_ value: String) -> Data? {
        // 按 76 列折行的 Base64 订阅很常见：先去掉所有空白和换行。
        var normalized = value.components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: normalized)
    }
}

public enum SubscriptionFetchError: Error, Equatable {
    case invalidHTTPStatus(Int)
}

public struct SubscriptionFetcher: Sendable {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 30) { self.timeout = timeout }

    public func fetch(from url: URL) async throws -> [SubscriptionNode] {
        try await fetchResult(from: url).nodes
    }

    /// 和 `fetch` 一样，另外带回跳过了哪些不支持的协议。
    public func fetchResult(from url: URL) async throws -> SubscriptionParseResult {
        let data: Data
        if url.scheme?.lowercased() == "file" {
            data = try Data(contentsOf: url)
        } else {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            let (body, response) = try await URLSession.shared.data(for: request)
            if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
                throw SubscriptionFetchError.invalidHTTPStatus(response.statusCode)
            }
            data = body
        }
        guard let text = String(data: data, encoding: .utf8) else { throw SubscriptionParseError.invalidBase64 }
        return try SubscriptionParser.parseResult(text)
    }
}
