import XCTest
import SafarierCore
@testable import SafarierNetwork

/// 用真实的 mihomo 验证进程生命周期：就绪检查、退出清理、配置错误时明确报错。
/// 需要设置 `SAFARIER_MIHOMO_BIN=/path/to/mihomo`，否则跳过。链式上游指向没人监听的端口，所以不需要网络。
final class MihomoProcessTests: XCTestCase {
    private func mihomoBinary() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["SAFARIER_MIHOMO_BIN"], !path.isEmpty else {
            throw XCTSkip("设置 SAFARIER_MIHOMO_BIN 后运行真实 mihomo 的生命周期测试")
        }
        return URL(fileURLWithPath: path)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("safarier-mihomo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// 上游指向 127.0.0.1:9（没人听），节点本身是一个 socks 条目；mihomo 启动时不拨号，只要监听就绪即可。
    private func chainedNode() -> SubscriptionNode {
        let upstream: JSONValue = .object([
            "name": .string("upstream"), "type": .string("socks5"), "server": .string("127.0.0.1"), "port": .int(9),
        ])
        let node: JSONValue = .object([
            "name": .string("leaf"), "type": .string("socks5"), "server": .string("127.0.0.1"), "port": .int(9),
            "dialer-proxy": .string("upstream"),
        ])
        return SubscriptionNode(name: "leaf", type: .socks, server: "127.0.0.1", serverPort: 9, mihomoProxies: [node, upstream])
    }

    func testOwnedStartIsReadyThenStopsAndLeavesNothingBehind() async throws {
        let binary = try mihomoBinary()
        let root = try temporaryRoot()
        let manager = SingboxProcessManager(engine: .mihomo, executableURL: binary, stateDirectory: root.appendingPathComponent("state"))
        let profileID = UUID()

        let identity = try await manager.startOwned(profileID: profileID, node: chainedNode(), timeoutSeconds: 20)
        XCTAssertEqual(identity.proxy.name, "mihomo")
        XCTAssertEqual(identity.proxy.host, "127.0.0.1")
        XCTAssertGreaterThan(identity.proxy.port, 0)
        XCTAssertFalse(identity.description.contains("leaf"), "identity must stay redacted")

        let exit = try await manager.stopOwned(identity)
        XCTAssertNotNil(exit, "mihomo should be observed exiting after the stop request")
        XCTAssertEqual(manager.pendingOwnedCount, 0)
    }

    /// 同一个 profile 的两次启动不能并存（端口和进程都只能有一份）。
    func testSecondOwnedStartForSameProfileIsRefused() async throws {
        let binary = try mihomoBinary()
        let root = try temporaryRoot()
        let manager = SingboxProcessManager(engine: .mihomo, executableURL: binary, stateDirectory: root.appendingPathComponent("state"))
        let profileID = UUID()
        let identity = try await manager.startOwned(profileID: profileID, node: chainedNode(), timeoutSeconds: 20)
        do {
            _ = try await manager.startOwned(profileID: profileID, node: chainedNode(), timeoutSeconds: 20)
            XCTFail("second start should be refused")
        } catch SingboxProcessError.alreadyRunning {
        }
        _ = try await manager.stopOwned(identity)
    }

    /// mihomo 拒绝配置（这里是不认识的协议类型）时要明确报错，不能当作"启动成功"。
    func testRejectedConfigFailsExplicitlyInsteadOfReportingReady() async throws {
        let binary = try mihomoBinary()
        let root = try temporaryRoot()
        let manager = SingboxProcessManager(engine: .mihomo, executableURL: binary, stateDirectory: root.appendingPathComponent("state"))
        let bad: JSONValue = .object(["name": .string("bad"), "type": .string("not-a-real-protocol"), "server": .string("127.0.0.1"), "port": .int(9)])
        let node = SubscriptionNode(name: "bad", type: .socks, server: "127.0.0.1", serverPort: 9, mihomoProxies: [bad])
        do {
            _ = try await manager.startOwned(profileID: UUID(), node: node, timeoutSeconds: 20)
            XCTFail("a rejected configuration must not report ready")
        } catch SingboxProcessError.exitedEarly {
        }
        XCTAssertEqual(manager.pendingOwnedCount, 0)
    }

    /// 用真实订阅文件（`SAFARIER_MIHOMO_TEST_CLASH`）逐个节点验证：经 owned 生命周期启动 mihomo，再经它的 SOCKS 端口请求一次外网。
    /// 订阅含凭据，所以只通过环境变量读取，不进入仓库。至少一个节点通过才算通过；失败的节点逐个打印原因。
    func testSubscriptionNodesReachTheInternetThroughMihomo() async throws {
        let binary = try mihomoBinary()
        guard let clash = ProcessInfo.processInfo.environment["SAFARIER_MIHOMO_TEST_CLASH"], !clash.isEmpty else {
            throw XCTSkip("设置 SAFARIER_MIHOMO_TEST_CLASH=/path/to/clash.yaml 后运行订阅节点的外网验证")
        }
        let nodes = try SubscriptionParser.parseResult(String(contentsOf: URL(fileURLWithPath: clash), encoding: .utf8)).nodes
        let root = try temporaryRoot()
        var passed = 0
        for node in nodes where node.proxyEngine == .mihomo {
            let manager = SingboxProcessManager(engine: .mihomo, executableURL: binary, stateDirectory: root.appendingPathComponent("state"))
            let label = "\(node.name) [\(node.type.rawValue)]"
            do {
                let identity = try await manager.startOwned(profileID: UUID(), node: node, timeoutSeconds: 20)
                let status = curlStatus(socksPort: identity.proxy.port)
                if status == "204" { passed += 1 }
                print("[mihomo-egress] \(label): HTTP \(status)")
                _ = try await manager.stopOwned(identity)
            } catch {
                print("[mihomo-egress] \(label): 启动失败 \(error)")
            }
            XCTAssertEqual(manager.pendingOwnedCount, 0, "\(label) left an owned process behind")
        }
        XCTAssertGreaterThan(passed, 0, "no subscription node reached the internet through mihomo")
    }

    /// 经 SOCKS5 本地端口请求 generate_204，返回 HTTP 状态码；失败时返回 curl 的错误摘要（不含凭据）。
    private func curlStatus(socksPort: Int) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-sS", "-m", "20", "--socks5-hostname", "127.0.0.1:\(socksPort)", "-o", "/dev/null",
                             "-w", "%{http_code}", "https://www.gstatic.com/generate_204"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return "curl 无法运行" }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return "失败（curl \(process.terminationStatus)：\(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))）"
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// 图形界面和 Runner 交互路径用的 legacy 启动：配置落盘（0600）、就绪后可停止，停止后文件全部删除。
    func testLegacyStartWritesPrivateConfigAndCleansUpOnStop() throws {
        let binary = try mihomoBinary()
        let root = try temporaryRoot()
        let state = root.appendingPathComponent("state", isDirectory: true)
        let manager = SingboxProcessManager(engine: .mihomo, executableURL: binary, stateDirectory: state)
        let profileID = UUID()

        _ = try manager.start(profileID: profileID, node: chainedNode())
        let configURL = manager.configurationFileURL(for: profileID)
        let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        _ = try manager.waitUntilReady(profileID: profileID, timeout: 20)
        XCTAssertTrue(manager.isRunning(profileID: profileID))

        try manager.stop(profileID: profileID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.pidFileURL(for: profileID).path))
    }
}
