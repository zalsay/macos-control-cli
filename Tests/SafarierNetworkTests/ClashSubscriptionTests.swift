import XCTest
@testable import SafarierNetwork

final class ClashSubscriptionTests: XCTestCase {
    func testClashYAMLImportsSupportedNodeAndReportsUnsupportedType() throws {
        let yaml = """
        ---
        proxies:
          - {name: example, type: ss, server: example.invalid, port: 8388, cipher: aes-128-gcm, password: fixture}
          - {name: unsupported, type: tuic, server: example.invalid, port: 443, uuid: fixture, password: fixture}
        """
        let result = try SubscriptionParser.parseResult(yaml)
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes.first?.type.rawValue, "shadowsocks")
        XCTAssertEqual(result.skippedSchemes["tuic"], 1)
    }
}

extension ClashSubscriptionTests {
    /// mihomo 后端原样保留配置（插件、指纹等），不再因为字段不在白名单里就整条丢掉。
    func testOptionsArePreservedInMihomoEntry() throws {
        let yaml = """
        proxies:
          - {name: obfuscated, type: ss, server: example.invalid, port: 8388, cipher: aes-128-gcm, password: fixture, plugin: obfs-local, plugin-opts: {mode: http}}
          - {name: safe, type: socks5, server: example.invalid, port: 1080}
        """
        let result = try SubscriptionParser.parseResult(yaml)
        XCTAssertEqual(result.nodes.map(\.type.rawValue), ["shadowsocks", "socks"])
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.nodes[0].mihomoProxies?.first?["plugin"], .string("obfs-local"))
        XCTAssertEqual(result.nodes[0].mihomoProxies?.first?["plugin-opts"], .object(["mode": .string("http")]))
    }
    func testMalformedClashNeverExposesPayload() {
        let yaml = "proxies: [ {name: PRIVATE_TOKEN, type: ss"
        XCTAssertThrowsError(try SubscriptionParser.parseResult(yaml)) { error in
            XCTAssertEqual(error as? SubscriptionParseError, .invalidClashYAML)
        }
    }
    func testAllUnsupportedProtocolsReportedWithoutNodeDetails() {
        let yaml = "proxies:\n  - {name: PRIVATE_TOKEN, type: tuic, server: example.invalid, port: 443}"
        XCTAssertThrowsError(try SubscriptionParser.parseResult(yaml)) { error in
            XCTAssertEqual(error as? SubscriptionParseError, .unsupportedClash(["tuic": 1]))
        }
    }
    func testBase64EncodedClashAndUnsupportedSummary() throws {
        let yaml = "proxies:\n  - {name: test, type: socks5, server: example.invalid, port: 1080}"
        let result = try SubscriptionParser.parseResult(Data(yaml.utf8).base64EncodedString())
        XCTAssertEqual(result.nodes.count, 1)
        let unsupported = "proxies:\n  - {name: one, type: wireguard}\n  - {name: two, type: tuic}"
        XCTAssertThrowsError(try InlineSubscription.store(unsupported, id: UUID(), in: FileManager.default.temporaryDirectory)) { error in
            XCTAssertEqual(error as? SubscriptionParseError, .unsupportedClash(["tuic": 1, "wireguard": 1]))
        }
    }
    func testBasicNodeTypesAndTLSSettingsArePreserved() throws {
        let yaml = """
        proxies:
          - {name: a, type: vless, server: a.invalid, port: 443, uuid: fixture, tls: true, servername: tls.invalid, skip-cert-verify: true}
          - {name: b, type: vmess, server: b.invalid, port: 443, uuid: fixture, alterId: 0, cipher: auto}
          - {name: c, type: trojan, server: c.invalid, port: 443, password: fixture, sni: tls.invalid}
          - {name: d, type: anytls, server: d.invalid, port: 443, password: fixture}
        """
        let nodes = try SubscriptionParser.parseResult(yaml).nodes
        XCTAssertEqual(nodes.map { $0.type.rawValue }, ["vless", "vmess", "trojan", "anytls"])
        XCTAssertTrue(nodes[0].tls); XCTAssertEqual(nodes[0].serverName, "tls.invalid")
        XCTAssertEqual(nodes[0].parameters["allowInsecure"], "true")
        XCTAssertEqual(nodes[1].alterID, 0); XCTAssertEqual(nodes[1].method, "auto")
        XCTAssertTrue(nodes[2].tls); XCTAssertTrue(nodes[3].tls)
    }
    func testFetcherLoadsClashFromFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let yaml = "proxies:\n  - {name: test, type: socks5, server: example.invalid, port: 1080}"
        try Data(yaml.utf8).write(to: file)
        let result = try await SubscriptionFetcher().fetchResult(from: file)
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes[0].type.rawValue, "socks")
    }
    func testWrongOptionalFieldTypesAreRejected() {
        let yaml = "proxies:\n  - {name: test, type: vless, server: a.invalid, port: 443, uuid: fixture, servername: 42}"
        XCTAssertThrowsError(try SubscriptionParser.parseResult(yaml)) { error in
            XCTAssertEqual(error as? SubscriptionParseError, .invalidClashYAML)
        }
    }
    /// 证书指纹、XUDP 现在都保留；上游缺失的链式节点明确计数跳过，摘要里只有协议名和原因，没有节点名或指纹。
    func testUnsafeCertificatePinAndDialerAreReportedWithoutValues() throws {
        let yaml = """
        proxies:
          - {name: secret-name, type: vless, server: private.invalid, port: 443, uuid: fixture, fingerprint: secret-pin, packet-encoding: xudp}
          - {name: second, type: vless, server: private.invalid, port: 443, uuid: fixture, fingerprint: secret-pin, packet-encoding: xudp, dialer-proxy: secret-proxy}
        """
        let result = try SubscriptionParser.parseResult(yaml)
        XCTAssertEqual(result.nodes.map(\.name), ["secret-name"])
        XCTAssertEqual(result.skippedSchemes, ["vless（链式代理上游无效）": 1])
        XCTAssertFalse(result.skippedSchemes.keys.contains { $0.contains("secret") })
    }
    /// `udp` 对 socks5 有效，mihomo 会用它，所以既保留也不提示。
    func testUdpOptionIsPreservedAndNotReportedForSocks() throws {
        let yaml = "proxies:\n  - {name: test, type: socks5, server: example.invalid, port: 1080, udp: false}"
        let result = try SubscriptionParser.parseResult(yaml)
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes[0].mihomoProxies?.first?["udp"], .bool(false))
        XCTAssertTrue(result.ignoredFields.isEmpty)
    }
    func testInlineClashRetainsFormatSpecificError() {
        let yaml = "proxies: [ {name: PRIVATE_TOKEN"
        XCTAssertThrowsError(try InlineSubscription.store(yaml, id: UUID(), in: FileManager.default.temporaryDirectory)) { error in
            XCTAssertEqual(error as? SubscriptionParseError, .invalidClashYAML)
        }
    }
}
