import Foundation

/// Protocols understood by the subscription parser and the proxy cores.
public enum SubscriptionNodeType: String, Codable, Sendable, CaseIterable {
    case vless
    case vmess
    case trojan
    case shadowsocks
    case socks
    case anytls
    /// 只出现在 Clash 订阅里，由 mihomo 后端运行。
    case hysteria2
}

/// A proxy node cached from a subscription.
public struct SubscriptionNode: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var type: SubscriptionNodeType
    public var server: String
    public var serverPort: Int
    public var uuid: String?
    /// SOCKS 认证用户名；其它协议不用。
    public var username: String?
    public var password: String?
    public var method: String?
    public var tls: Bool
    public var serverName: String?
    public var transport: String?
    public var transportPath: String?
    public var transportHost: String?
    public var flow: String?
    public var alterID: Int?
    /// Protocol-specific values retained from the URI query string.
    public var parameters: [String: String]
    /// mihomo 后端的节点：订阅里原样保留的 Clash 代理条目。节点自己在第一个，之后是它经 `dialer-proxy` 依赖的上游，
    /// 一直到没有上游为止。nil 表示 sing-box 后端（URI 节点）。
    public var mihomoProxies: [JSONValue]?

    public init(
        id: UUID = UUID(),
        name: String,
        type: SubscriptionNodeType,
        server: String,
        serverPort: Int,
        uuid: String? = nil,
        username: String? = nil,
        password: String? = nil,
        method: String? = nil,
        tls: Bool = false,
        serverName: String? = nil,
        transport: String? = nil,
        transportPath: String? = nil,
        transportHost: String? = nil,
        flow: String? = nil,
        alterID: Int? = nil,
        parameters: [String: String] = [:],
        mihomoProxies: [JSONValue]? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.server = server
        self.serverPort = serverPort
        self.uuid = uuid
        self.username = username
        self.password = password
        self.method = method
        self.tls = tls
        self.serverName = serverName
        self.transport = transport
        self.transportPath = transportPath
        self.transportHost = transportHost
        self.flow = flow
        self.alterID = alterID
        self.parameters = parameters
        self.mihomoProxies = mihomoProxies
    }

    public func validate() throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw SubscriptionNodeValidationError.emptyName }
        if let mihomoProxies {
            // 配置里要有节点自己的条目，否则 mihomo 的 select 组会指向不存在的代理。
            guard mihomoProxies.contains(where: { $0["name"]?.stringValue == name }) else {
                throw SubscriptionNodeValidationError.invalidProxyChain
            }
        }
        guard !server.isEmpty, !server.contains(where: { $0.isWhitespace }), !server.contains("/") else {
            throw SubscriptionNodeValidationError.invalidServer(server)
        }
        guard (1...65535).contains(serverPort) else {
            throw SubscriptionNodeValidationError.invalidPort(serverPort)
        }
        switch type {
        case .vless, .vmess:
            guard let uuid, !uuid.isEmpty else { throw SubscriptionNodeValidationError.missingIdentity }
        case .trojan, .anytls, .hysteria2:
            guard let password, !password.isEmpty else { throw SubscriptionNodeValidationError.missingCredential }
        case .socks:
            // 用户名、密码都可以没有（无认证）；只给密码没给用户名的 SOCKS5 认证不成立。
            if password?.isEmpty == false, username?.isEmpty ?? true {
                throw SubscriptionNodeValidationError.missingIdentity
            }
        case .shadowsocks:
            guard let method, !method.isEmpty, let password, !password.isEmpty else {
                throw SubscriptionNodeValidationError.missingCredential
            }
        }
    }
}

public typealias ProxyNode = SubscriptionNode
public typealias NodeProtocol = SubscriptionNodeType

public enum SubscriptionNodeValidationError: Error, Equatable {
    case emptyName
    case invalidServer(String)
    case invalidPort(Int)
    case missingIdentity
    case missingCredential
    /// mihomo 节点的条目里找不到节点自己（配置被改坏或解析不完整）。
    case invalidProxyChain
}

/// A subscription and its last successfully parsed node cache.
public struct Subscription: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var url: URL
    public let createdAt: Date
    public var updatedAt: Date?
    public var nodes: [SubscriptionNode]

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        nodes: [SubscriptionNode] = []
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.nodes = nodes
    }

    public func validate() throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw SubscriptionValidationError.emptyName }
        guard trimmedName.count <= 128 else { throw SubscriptionValidationError.nameTooLong(trimmedName.count) }
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https", "file"].contains(scheme) else {
            throw SubscriptionValidationError.unsupportedURLScheme(scheme)
        }
        if scheme != "file" && url.host == nil {
            throw SubscriptionValidationError.invalidURL(url.absoluteString)
        }
        for node in nodes { try node.validate() }
    }
}

public enum SubscriptionValidationError: Error, Equatable {
    case emptyName
    case nameTooLong(Int)
    case unsupportedURLScheme(String)
    case invalidURL(String)
}

extension Subscription: ValidatableRecord {}

public typealias SubscriptionRepository = RecordRepository<Subscription>

public extension RecordRepository where Record == Subscription {
    /// File layout: `directory/subscriptions.json`.
    static func subscriptions(in directory: URL) -> SubscriptionRepository {
        RecordRepository(store: JSONDocumentStore<Subscription>(
            fileURL: directory.appendingPathComponent("subscriptions.json")
        ))
    }
}
