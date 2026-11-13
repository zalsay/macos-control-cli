import Foundation
import SafarierCore

public enum MihomoConfigError: Error, Equatable {
    case invalidInboundPort(Int)
    /// 节点没有 mihomo 条目（它是 sing-box 节点），不能用 mihomo 运行。
    case notAMihomoNode
    case invalidNode(SubscriptionNodeValidationError)
}

/// mihomo 配置：一个只听 127.0.0.1 的 SOCKS5 入站，里面只有所选节点和它的链式上游（都是订阅里原样保留的条目），
/// 一个只含这个节点的 select 组，所有流量 MATCH 到它。没有 API、没有 DNS 监听、没有其它入站，节点断了不会退回直连。
/// 配置里有节点凭据，写出时只给当前用户读写。
public enum MihomoConfigBuilder {
    public static let proxyGroupName = "safarier"

    public static func makeConfiguration(inboundPort: Int, node: SubscriptionNode) throws -> JSONValue {
        guard (1...65535).contains(inboundPort) else { throw MihomoConfigError.invalidInboundPort(inboundPort) }
        do { try node.validate() } catch let error as SubscriptionNodeValidationError {
            throw MihomoConfigError.invalidNode(error)
        }
        guard let proxies = node.mihomoProxies else { throw MihomoConfigError.notAMihomoNode }
        return .object([
            "socks-port": .int(inboundPort),
            "bind-address": .string(SingboxConfigBuilder.defaultInboundAddress),
            "allow-lan": .bool(false),
            "mode": .string("rule"),
            // 不用 warning：mihomo 的拨号失败日志会带上目标域名，sing-box 的 warn 级别没有这个问题，这里保持同样不记访问记录。
            "log-level": .string("error"),
            // 订阅原文是 ipv6: true，保持一致（节点地址可能是 IPv6）。
            "ipv6": .bool(true),
            "find-process-mode": .string("off"),
            "profile": .object(["store-selected": .bool(false), "store-fake-ip": .bool(false)]),
            "proxies": .array(proxies),
            "proxy-groups": .array([.object([
                "name": .string(proxyGroupName),
                "type": .string("select"),
                "proxies": .array([.string(node.name)]),
            ])]),
            "rules": .array([.string("MATCH,\(proxyGroupName)")]),
        ])
    }

    /// 写进 mihomo 的配置文件（JSON 是 YAML 的子集，mihomo 直接接受）。
    public static func build(inboundPort: Int, node: SubscriptionNode) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(makeConfiguration(inboundPort: inboundPort, node: node))
    }
}
