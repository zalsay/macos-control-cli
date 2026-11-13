import Foundation

/// mihomo 对每种代理条目认识的顶层字段（来自 mihomo v1.19.33 的 `*Option` 结构体 `proxy:"…"` 标签，加上 `BasicOption`）。
///
/// mihomo 解码时会静默忽略不认识的字段（`mihomo -t` 照样通过），所以导入时要对照这张表，把它会忽略的字段明确列出来，
/// 而不是悄悄丢掉。键名比较和 mihomo 一致：大小写不敏感，`_` 视同 `-`。
/// mihomo 升级时要重新从源码提取这张表（scripts/build-mihomo.sh 固定的版本就是它对应的版本）。
enum MihomoProxyFields {
    /// 所有协议都有的字段：`BasicOption` 加上 `name`、`type`、`server`、`port`（`udp` 不是所有协议都有，放在各协议自己的表里）。
    static let common: Set<String> = [
        "name", "type", "server", "port",
        "dialer-proxy", "interface-name", "ip-version", "mptcp", "routing-mark", "tfo",
    ]

    /// 按 Clash 的 `type` 取认识的字段（不含 `common`）。没有表的类型返回 nil（不检查它的字段）。
    static func specific(for clashType: String) -> Set<String>? {
        switch clashType {
        case "ss":
            return ["cipher", "client-fingerprint", "password", "plugin", "plugin-opts", "udp", "udp-over-tcp", "udp-over-tcp-version"]
        case "socks5":
            return ["certificate", "fingerprint", "name-cert-verify", "password", "private-key", "skip-cert-verify", "tls", "udp", "username"]
        case "vless":
            return [
                "alpn", "certificate", "client-fingerprint", "ech-opts", "encryption", "fingerprint", "flow", "grpc-opts",
                "h2-opts", "http-opts", "jls-opts", "name-cert-verify", "network", "packet-addr", "packet-encoding",
                "private-key", "reality-opts", "restls-opts", "servername", "shadow-tls-opts", "skip-cert-verify", "tls",
                "udp", "uuid", "ws-headers", "ws-opts", "xhttp-opts", "xudp",
            ]
        case "vmess":
            return [
                "alpn", "alterId", "authenticated-length", "certificate", "cipher", "client-fingerprint", "ech-opts",
                "fingerprint", "global-padding", "grpc-opts", "h2-opts", "http-opts", "jls-opts", "mekya-opts", "mkcp-opts",
                "name-cert-verify", "network", "packet-addr", "packet-encoding", "private-key", "reality-opts", "restls-opts",
                "servername", "shadow-tls-opts", "skip-cert-verify", "tls", "tlsmirror-opts", "udp", "uuid", "ws-opts", "xudp",
            ]
        case "trojan":
            return [
                "alpn", "certificate", "client-fingerprint", "ech-opts", "fingerprint", "grpc-opts", "jls-opts",
                "name-cert-verify", "network", "password", "private-key", "reality-opts", "restls-opts", "shadow-tls-opts",
                "skip-cert-verify", "sni", "ss-opts", "udp", "ws-opts",
            ]
        case "anytls":
            return [
                "alpn", "certificate", "client-fingerprint", "client-metadata", "disable-reuse", "ech-opts", "fingerprint",
                "idle-session-check-interval", "idle-session-timeout", "jls-opts", "min-idle-session", "name-cert-verify",
                "password", "private-key", "restls-opts", "shadow-tls-opts", "skip-cert-verify", "sni", "udp",
            ]
        case "hysteria2":
            return [
                "alpn", "bbr-profile", "certificate", "cwnd", "down", "ech-opts", "fingerprint", "handshake-timeout",
                "hop-interval", "initial-connection-receive-window", "initial-stream-receive-window",
                "max-connection-receive-window", "max-stream-receive-window", "name-cert-verify", "obfs",
                "obfs-max-packet-size", "obfs-min-packet-size", "obfs-password", "password", "ports", "private-key",
                "realm-opts", "skip-cert-verify", "sni", "udp-mtu", "up",
            ]
        default:
            return nil
        }
    }

    /// 条目里 mihomo 会忽略的顶层字段（键名原样返回，升序）。没有表的类型返回空。
    static func ignoredKeys(in object: [String: Any], clashType: String) -> [String] {
        guard let known = specific(for: clashType) else { return [] }
        let accepted = known.union(common)
        return object.keys.filter { key in
            !accepted.contains(key.lowercased().replacingOccurrences(of: "_", with: "-"))
        }.sorted()
    }
}
