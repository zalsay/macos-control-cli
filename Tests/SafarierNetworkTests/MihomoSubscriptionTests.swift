import XCTest
import SafarierCore
@testable import SafarierNetwork

/// Clash 订阅进 mihomo 后端的解析规则：条目原样保留、链式代理按 dialer-proxy 收集上游、未知字段明确提示。
final class MihomoSubscriptionTests: XCTestCase {
    private let chainYAML = """
    proxies:
      - {name: UP, type: hysteria2, server: up.invalid, port: 5183, password: fixture, sni: up.invalid, skip-cert-verify: false, fingerprint: "AA:BB", udp: true}
      - {name: MID, type: vless, server: mid.invalid, port: 443, uuid: fixture, tls: true, servername: mid.invalid, fingerprint: "CC:DD", network: tcp, udp: true, packet-encoding: xudp, dialer-proxy: UP}
      - {name: LEAF, type: vless, server: leaf.invalid, port: 443, uuid: fixture, tls: true, servername: leaf.invalid, udp: true, dialer-proxy: MID}
      - {name: PLAIN, type: vless, server: plain.invalid, port: 443, uuid: fixture, tls: true}
    """

    func testHysteria2IsImportedWithCredentialsAndTLS() throws {
        let result = try SubscriptionParser.parseResult(chainYAML)
        let up = try XCTUnwrap(result.nodes.first { $0.name == "UP" })
        XCTAssertEqual(up.type, .hysteria2)
        XCTAssertEqual(up.password, "fixture")
        XCTAssertTrue(up.tls)
        XCTAssertEqual(up.transport, "quic")
        XCTAssertEqual(up.serverName, "up.invalid")
        XCTAssertEqual(up.mihomoProxies?.first?["fingerprint"], .string("AA:BB"))
    }

    /// 链式节点的条目里是它自己，然后依次是它的上游（dialer-proxy 指向的条目），一直到头。
    func testChainCollectsUpstreamsInDependencyOrder() throws {
        let nodes = try SubscriptionParser.parseResult(chainYAML).nodes
        let leaf = try XCTUnwrap(nodes.first { $0.name == "LEAF" })
        XCTAssertEqual(leaf.mihomoProxies?.compactMap { $0["name"]?.stringValue }, ["LEAF", "MID", "UP"])
        let plain = try XCTUnwrap(nodes.first { $0.name == "PLAIN" })
        XCTAssertEqual(plain.mihomoProxies?.compactMap { $0["name"]?.stringValue }, ["PLAIN"])
    }

    func testMissingUpstreamIsSkippedWithoutNames() throws {
        let yaml = """
        proxies:
          - {name: ORPHAN, type: vless, server: a.invalid, port: 443, uuid: fixture, dialer-proxy: GONE}
          - {name: OK, type: socks5, server: b.invalid, port: 1080}
        """
        let result = try SubscriptionParser.parseResult(yaml)
        XCTAssertEqual(result.nodes.map(\.name), ["OK"])
        XCTAssertEqual(result.skippedSchemes, ["vless（链式代理上游无效）": 1])
    }

    /// 成环的链式代理不会死循环；两个节点都连不上，没有可导入的节点时整份报错并列出原因。
    func testChainCycleIsSkippedInsteadOfLooping() {
        let yaml = """
        proxies:
          - {name: A, type: vless, server: a.invalid, port: 443, uuid: fixture, dialer-proxy: B}
          - {name: B, type: vless, server: b.invalid, port: 443, uuid: fixture, dialer-proxy: A}
        """
        XCTAssertThrowsError(try SubscriptionParser.parseResult(yaml)) { error in
            XCTAssertEqual(error as? SubscriptionParseError, .unsupportedClash(["vless（链式代理上游无效）": 2]))
        }
    }

    /// 重名的后出现的条目不参与（mihomo 会拒绝重名），计数跳过，不静默覆盖。
    func testDuplicateNameIsCountedNotSilentlyKept() throws {
        let yaml = """
        proxies:
          - {name: SAME, type: socks5, server: first.invalid, port: 1080}
          - {name: SAME, type: socks5, server: second.invalid, port: 1081}
        """
        let result = try SubscriptionParser.parseResult(yaml)
        XCTAssertEqual(result.nodes.map(\.server), ["first.invalid"])
        XCTAssertEqual(result.skippedSchemes, ["重名节点": 1])
    }

    /// mihomo 解码时会静默忽略不认识的字段，这里要明确列出来；节点照常导入。
    func testUnknownFieldIsReportedAndNodeStillImported() throws {
        let yaml = """
        proxies:
          - {name: T, type: vless, server: t.invalid, port: 443, uuid: fixture, secret-typo-option: fixture-value}
        """
        let result = try SubscriptionParser.parseResult(yaml)
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.ignoredFields, ["vless.secret-typo-option": 1])
        XCTAssertTrue(result.hasNotices)
        XCTAssertFalse(String(describing: result.ignoredFields).contains("fixture-value"))
    }

    /// 键名比较和 mihomo 一致：大小写不敏感，下划线等同连字符。这里只检查"不误报"；
    /// 列表里的 sni 等显示字段仍按规范键名读取。
    func testFieldNamesMatchMihomoCaseAndUnderscoreRules() throws {
        let yaml = """
        proxies:
          - {name: C, type: trojan, server: c.invalid, port: 443, password: fixture, Skip_Cert_Verify: true, sni: c.invalid}
        """
        let result = try SubscriptionParser.parseResult(yaml)
        XCTAssertTrue(result.ignoredFields.isEmpty)
        XCTAssertEqual(result.nodes.count, 1)
    }

    /// hysteria2 没有 udp 选项（它本来就走 UDP），mihomo 会忽略它，所以要提示，而不是跳过节点。
    func testHysteria2UdpIsReportedButNodeIsKept() throws {
        let result = try SubscriptionParser.parseResult(chainYAML)
        XCTAssertEqual(result.ignoredFields["hysteria2.udp"], 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertTrue(result.nodes.contains { $0.name == "UP" })
    }

    func testNonStringDialerProxyIsRejected() {
        let yaml = """
        proxies:
          - {name: A, type: vless, server: a.invalid, port: 443, uuid: fixture, dialer-proxy: 12}
        """
        XCTAssertThrowsError(try SubscriptionParser.parseResult(yaml)) { error in
            XCTAssertEqual(error as? SubscriptionParseError, .invalidClashYAML)
        }
    }

    /// 嵌套结构（ws-opts、reality-opts）原样保留，包括数字和布尔值的类型。
    func testNestedOptionsKeepTheirTypes() throws {
        let yaml = """
        proxies:
          - name: N
            type: vless
            server: n.invalid
            port: 443
            uuid: fixture
            tls: true
            ws-opts: {path: /ws, headers: {Host: n.invalid}, max-early-data: 2048, early-data-header-name: Sec-WebSocket-Protocol}
            reality-opts: {public-key: fixture, short-id: abcd}
            udp: true
        """
        let entry = try XCTUnwrap(SubscriptionParser.parseResult(yaml).nodes.first?.mihomoProxies?.first)
        XCTAssertEqual(entry["ws-opts"]?["max-early-data"], .int(2048))
        XCTAssertEqual(entry["ws-opts"]?["headers"]?["Host"], .string("n.invalid"))
        XCTAssertEqual(entry["reality-opts"]?["short-id"], .string("abcd"))
        XCTAssertEqual(entry["udp"], .bool(true))
        XCTAssertEqual(entry["port"], .int(443))
    }

    func testNodeMustContainItsOwnEntry() {
        let node = SubscriptionNode(name: "A", type: .socks, server: "a.invalid", serverPort: 1080,
                                    mihomoProxies: [.object(["name": .string("B"), "type": .string("socks5")])])
        XCTAssertThrowsError(try node.validate()) { error in
            XCTAssertEqual(error as? SubscriptionNodeValidationError, .invalidProxyChain)
        }
    }

    func testMihomoNodeIsNotTranslatedForSingbox() {
        let node = SubscriptionNode(name: "A", type: .socks, server: "a.invalid", serverPort: 1080,
                                    mihomoProxies: [.object(["name": .string("A"), "type": .string("socks5")])])
        XCTAssertThrowsError(try SingboxConfigBuilder.makeConfiguration(inboundPort: 20001, node: node)) { error in
            XCTAssertEqual(error as? SingboxConfigError, .requiresMihomo)
        }
    }

    func testHysteria2IsNotTranslatedForSingbox() {
        let node = SubscriptionNode(name: "H", type: .hysteria2, server: "h.invalid", serverPort: 443, password: "fixture")
        XCTAssertThrowsError(try SingboxConfigBuilder.makeConfiguration(inboundPort: 20001, node: node)) { error in
            XCTAssertEqual(error as? SingboxConfigError, .unsupportedType(.hysteria2))
        }
    }

    func testEngineFollowsWhetherNodeHasMihomoEntries() throws {
        let nodes = try SubscriptionParser.parseResult(chainYAML).nodes
        XCTAssertEqual(nodes.first { $0.name == "UP" }?.proxyEngine, .mihomo)
        let uri = SubscriptionNode(name: "U", type: .trojan, server: "u.invalid", serverPort: 443, password: "fixture")
        XCTAssertEqual(uri.proxyEngine, .singbox)
    }
}
