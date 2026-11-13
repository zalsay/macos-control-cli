import XCTest
import SafarierCore
@testable import SafarierNetwork

final class MihomoConfigTests: XCTestCase {
    private func chainedNode() throws -> SubscriptionNode {
        let yaml = """
        proxies:
          - {name: UP, type: hysteria2, server: up.invalid, port: 5183, password: fixture, sni: up.invalid, fingerprint: "AA:BB"}
          - {name: LEAF, type: vless, server: leaf.invalid, port: 443, uuid: fixture, tls: true, servername: leaf.invalid, fingerprint: "CC:DD", packet-encoding: xudp, dialer-proxy: UP}
          - {name: OTHER, type: socks5, server: other.invalid, port: 1080}
        """
        return try XCTUnwrap(SubscriptionParser.parseResult(yaml).nodes.first { $0.name == "LEAF" })
    }

    func testConfigIsLocalSocksOnlyWithNoControlOrDNSListeners() throws {
        let config = try MihomoConfigBuilder.makeConfiguration(inboundPort: 20123, node: chainedNode())
        XCTAssertEqual(config["socks-port"], .int(20123))
        XCTAssertEqual(config["bind-address"], .string("127.0.0.1"))
        XCTAssertEqual(config["allow-lan"], .bool(false))
        for key in ["external-controller", "mixed-port", "port", "redir-port", "tproxy-port", "dns", "tun", "listeners"] {
            XCTAssertNil(config[key], "unexpected listener or API key: \(key)")
        }
    }

    /// 配置里的代理条目就是订阅原样保留的内容：指纹、XUDP、TLS、链式上游都在。
    func testChainedEntriesKeepFingerprintXudpTLSAndDialerProxy() throws {
        let config = try MihomoConfigBuilder.makeConfiguration(inboundPort: 20123, node: chainedNode())
        guard case .array(let proxies) = config["proxies"] else { return XCTFail("proxies missing") }
        XCTAssertEqual(proxies.compactMap { $0["name"]?.stringValue }, ["LEAF", "UP"])
        XCTAssertFalse(proxies.contains { $0["name"] == .string("OTHER") }, "unrelated nodes must not be written")
        XCTAssertEqual(proxies[0]["fingerprint"], .string("CC:DD"))
        XCTAssertEqual(proxies[0]["packet-encoding"], .string("xudp"))
        XCTAssertEqual(proxies[0]["tls"], .bool(true))
        XCTAssertEqual(proxies[0]["dialer-proxy"], .string("UP"))
        XCTAssertEqual(proxies[1]["fingerprint"], .string("AA:BB"))
    }

    func testSelectGroupAndRulesRouteEverythingToTheChosenNode() throws {
        let config = try MihomoConfigBuilder.makeConfiguration(inboundPort: 20123, node: chainedNode())
        guard case .array(let groups) = config["proxy-groups"], case .object(let group)? = groups.first else {
            return XCTFail("proxy-groups missing")
        }
        XCTAssertEqual(group["type"], .string("select"))
        XCTAssertEqual(group["proxies"], .array([.string("LEAF")]))
        XCTAssertEqual(config["rules"], .array([.string("MATCH,\(MihomoConfigBuilder.proxyGroupName)")]))
    }

    /// 不用 warning：拨号失败日志会带目标域名。
    func testLogLevelDoesNotRecordVisitedHosts() throws {
        let config = try MihomoConfigBuilder.makeConfiguration(inboundPort: 20123, node: chainedNode())
        XCTAssertEqual(config["log-level"], .string("error"))
    }

    func testWrittenFileIsValidJSONThatMihomoCanRead() throws {
        let data = try MihomoConfigBuilder.build(inboundPort: 20123, node: chainedNode())
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, try MihomoConfigBuilder.makeConfiguration(inboundPort: 20123, node: chainedNode()))
    }

    func testSingboxNodeCannotBeConfiguredForMihomo() {
        let node = SubscriptionNode(name: "U", type: .trojan, server: "u.invalid", serverPort: 443, password: "fixture")
        XCTAssertThrowsError(try MihomoConfigBuilder.makeConfiguration(inboundPort: 20123, node: node)) { error in
            XCTAssertEqual(error as? MihomoConfigError, .notAMihomoNode)
        }
    }

    func testInvalidPortIsRejected() throws {
        let node = try chainedNode()
        XCTAssertThrowsError(try MihomoConfigBuilder.makeConfiguration(inboundPort: 0, node: node)) { error in
            XCTAssertEqual(error as? MihomoConfigError, .invalidInboundPort(0))
        }
    }

    func testJSONValueRoundTripsEveryCase() throws {
        let value: JSONValue = .object([
            "null": .null, "bool": .bool(true), "int": .int(443), "double": .double(1.5),
            "string": .string("a,b"), "array": .array([.int(1), .string("x")]), "object": .object(["k": .bool(false)]),
        ])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    func testExecutableNamesAndMatching() {
        XCTAssertEqual(ProxyCoreEngine.mihomo.executableName, "mihomo")
        XCTAssertEqual(ProxyCoreEngine.matching(executableURL: URL(fileURLWithPath: "/x/mihomo")), .mihomo)
        XCTAssertEqual(ProxyCoreEngine.matching(executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/sing-box")), .singbox)
        XCTAssertNil(ProxyCoreEngine.matching(executableURL: URL(fileURLWithPath: "/bin/ls")))
    }

    func testMissingMihomoErrorExplainsHowToFixIt() {
        let text = "\(SingboxProcessError.executableNotFound(URL(fileURLWithPath: "/opt/homebrew/bin/mihomo")))"
        XCTAssertTrue(text.contains("找不到 mihomo"), text)
        XCTAssertTrue(text.contains("brew install mihomo") && text.contains("SAFARIER_MIHOMO"), text)
    }

    func testMihomoOverrideEnvironmentVariableIsIndependent() {
        let environment = ["SAFARIER_MIHOMO": "/opt/custom/mihomo", "SAFARIER_SINGBOX": "/opt/custom/sing-box"]
        XCTAssertEqual(ProxyCoreEngine.mihomo.locateExecutable(environment: environment, bundledExecutable: nil)?.path, "/opt/custom/mihomo")
        XCTAssertEqual(ProxyCoreEngine.singbox.locateExecutable(environment: environment, bundledExecutable: nil)?.path, "/opt/custom/sing-box")
    }
}
