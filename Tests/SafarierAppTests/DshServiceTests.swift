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
}
