import Darwin
import XCTest
@testable import Safarier

@MainActor
final class DshServiceTests: XCTestCase {
    func testLocateDedicatedBinary() {
        let service = DshService.shared
        let binary = service.locateBinary()
        XCTAssertNotNil(binary, "应该能够找到 Safarier 内置或工作区构建的 dsh 二进制")

        if let binary {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary))
            XCTAssertFalse(binary.contains("/.local/bin/dsh"), "严禁回退到系统 ~/.local/bin/dsh")
            XCTAssertFalse(binary.contains("/opt/homebrew/bin/dsh"), "严禁回退到系统 /opt/homebrew/bin/dsh")
        }
    }

    func testGetOrCreateWebViewReusesExistingInstance() {
        let service = DshService.shared
        let url1 = URL(string: "http://127.0.0.1:58432/?auth=token1")!
        let wv1 = service.getOrCreateWebView(for: url1)
        XCTAssertNotNil(wv1)
        XCTAssertIdentical(service.cachedWebView, wv1)

        // 再次获取相同主机与端口的 URL，应当复用同一个 WKWebView 实例，避免切页重新加载
        let wv2 = service.getOrCreateWebView(for: url1)
        XCTAssertIdentical(wv1, wv2, "在切页重新进入时应当复用同一个 WKWebView 实例")

        // 停止服务时应当清理 cachedWebView
        service.stop()
        XCTAssertNil(service.cachedWebView, "服务停止时应当清空 cachedWebView")
    }

    func testDshLANListenerIsOptInAndBoundToAnAssignedPrivateIPv4() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-lan-config-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent(DshLANConfiguration.fileName)
        let enabled = Data(#"{"version":1,"enabled":true,"bindAddress":"10.0.0.108"}"#.utf8)
        try enabled.write(to: configURL)

        // A loose/default-permission file cannot opt into a LAN listener.
        XCTAssertEqual(chmod(configURL.path, 0o644), 0)
        XCTAssertNil(DshLANConfiguration.load(from: configURL, localIPv4Addresses: ["10.0.0.108"]))
        XCTAssertEqual(chmod(configURL.path, 0o600), 0)
        XCTAssertNotNil(DshLANConfiguration.load(from: configURL, localIPv4Addresses: ["10.0.0.108"]))
        XCTAssertNil(DshLANConfiguration.load(from: configURL, localIPv4Addresses: ["10.0.0.109"]))
        XCTAssertNil(DshLANConfiguration.load(from: configURL, localIPv4Addresses: ["8.8.8.8"]))

        try Data(#"{"version":1,"enabled":false,"bindAddress":"10.0.0.108"}"#.utf8).write(to: configURL)
        XCTAssertEqual(chmod(configURL.path, 0o600), 0)
        XCTAssertNil(DshLANConfiguration.load(from: configURL, localIPv4Addresses: ["10.0.0.108"]))
    }

    func testDshArgumentsKeepLoopbackDefaultAndUseExactLANAuthority() {
        XCTAssertEqual(DshLANConfiguration.arguments(for: nil), ["web", "--no-open", "--port", "61919"])
        XCTAssertEqual(DshLANConfiguration.arguments(for: DshLANConfiguration(bindAddress: "10.0.0.108")), [
            "web", "--no-open", "--port", "61919",
            "--host", "10.0.0.108",
            "--public-url", "https://i.meetlife.com.cn:3000/dsh-mac/",
            "--trusted-host", "i.meetlife.com.cn:3000",
        ])
    }

    func testPublicStartupTokenIsRedactedAndLocalBootstrapStaysOnMacAddress() throws {
        let secret = "native-only-test-token"
        let advertised = try XCTUnwrap(URL(string: "https://i.meetlife.com.cn:3000/dsh-mac/?token=\(secret)"))
        XCTAssertTrue(DshStartupURL.isExpectedPublicURL(advertised))
        XCTAssertEqual(DshStartupURL.token(in: advertised), secret)
        let local = try XCTUnwrap(DshStartupURL.localBootstrapURL(bindAddress: "10.0.0.108", token: secret))
        XCTAssertEqual(local.scheme, "http")
        XCTAssertEqual(local.host, "10.0.0.108")
        XCTAssertEqual(local.port, 61919)
        XCTAssertEqual(URLComponents(url: local, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, secret)
        XCTAssertFalse(DshStartupURL.sanitizedLog("dsh web: \(advertised.absoluteString)").contains(secret))
        XCTAssertFalse(DshStartupURL.isExpectedPublicURL(try XCTUnwrap(URL(string: "https://i.meetlife.com.cn:3000/dsh-mac/?token=one&token=two"))))
    }
}
