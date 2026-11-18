#if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_CONTROL_TESTING
import AppKit
import WebKit
import XCTest
import SafarierCore
import SafarierWebKit
@testable import Safarier

@MainActor
final class RegisteredFileSelectionTests: XCTestCase {
    func testLocalPageReadsTwoSelectedFilesFromItsOriginalChooser() async throws {
        _ = NSApplication.shared
        let profile = Profile(name: "file-selection-test", mode: .ephemeral)
        let factory = WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), safariApplicationName: "Version/26.2 Safari/605.1.15")
        let output = try factory.make(profile: profile, proxy: nil, processLanguages: [])
        let session = BrowserSession(profile: profile, output: output, outboundDescription: "offline", diagnostics: SPIDiagnostics())
        let controller = session.openWindow(url: nil)
        defer { controller.window.close() }
        let webView = controller.webView
        webView.loadHTMLString("""
            <input type="file" id="picker" multiple>
            <script>
              picker.onchange = async () => {
                window.picked = await Promise.all([...picker.files].map(async f => [f.name, await f.text()]));
              };
            </script>
            """, baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(8)
        var ready = false
        repeat {
            ready = (try? await webView.evaluateJavaScript("!!document.getElementById('picker')")) as? Bool == true
            if !ready { try await Task.sleep(for: .milliseconds(30)) }
        } while !ready && ContinuousClock.now < deadline
        XCTAssertTrue(ready)

        let lease = try controller.beginRegisteredControl()
        defer { _ = lease.restore(inputDrained: true) }
        let identity = AutomationTargetIdentity(profileID: profile.id, runnerInstanceID: UUID(), windowID: UUID(), pageID: UUID())
        let viewport = AutomationViewport(viewportWidthPoints: 100, viewportHeightPoints: 100, pixelWidth: 100, pixelHeight: 100,
                                          scaleX: 1, scaleY: 1, pageZoom: 1, viewVersion: 1)
        let token = try AutomationSessionToken.generate()
        let broker = ControlBroker(testSender: { request in
            let result: AutomationResult
            switch request.action {
            case .openSession: result = .sessionOpened(sessionID: token, target: identity, viewport: viewport)
            case .selectFiles(let paths):
                XCTAssertEqual(request.sessionID, token)
                result = .filesSelected(count: try controller.selectRegisteredFiles(paths, leaseID: lease.id))
            default: throw AutomationError(code: .invalidRequest)
            }
            return AutomationReply(requestID: request.requestID, outcome: .success(result))
        })
        func send(_ operation: ControlOperation) async throws -> ControlBrokerReply {
            let (data, ack) = await broker.handle(ControlRequest(requestID: UUID(), operation: operation))
            if let ack { broker.acknowledgement(ack, received: true) }
            return try JSONDecoder().decode(ControlBrokerReply.self, from: data)
        }
        let connected = try await send(.connect(profileID: profile.id))
        let connection = try XCTUnwrap(connected.connection)
        let noChooser = try await send(.selectFile(connection: connection, paths: ["/tmp/no-chooser"]))
        XCTAssertEqual(noChooser.error, "FILE_DIALOG_NOT_FOUND")
        _ = try await webView.evaluateJavaScript("document.getElementById('picker').click(); true")
        let chooserDeadline = ContinuousClock.now + .seconds(5)
        while controller.window.attachedSheet == nil && ContinuousClock.now < chooserDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let panel = try XCTUnwrap(controller.window.attachedSheet as? NSOpenPanel)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("封面 01.txt"), second = dir.appendingPathComponent("page 02.txt")
        try Data("cover".utf8).write(to: first)
        try Data("page".utf8).write(to: second)
        XCTAssertThrowsError(try controller.selectRegisteredFiles([first.path], leaseID: UUID())) {
            XCTAssertEqual(($0 as? AutomationError)?.code, .targetChanged)
        }
        let invalid = try await send(.selectFile(connection: connection, paths: [first.path, dir.path]))
        XCTAssertEqual(invalid.error, "FILE_NOT_READABLE")
        XCTAssertNil(invalid.filesSelected)
        XCTAssertTrue(controller.window.attachedSheet === panel)
        let receipt = try await send(.selectFile(connection: connection, paths: [first.path, second.path]))
        XCTAssertEqual(receipt.status, "ok")
        XCTAssertEqual(receipt.filesSelected, 2)
        XCTAssertEqual(receipt.sent, true)
        XCTAssertEqual(receipt.effectVerified, false)
        let consumed = try await send(.selectFile(connection: connection, paths: [first.path]))
        XCTAssertEqual(consumed.error, "FILE_DIALOG_NOT_FOUND")
        let resultDeadline = ContinuousClock.now + .seconds(5)
        var selected: [[String]]?
        repeat {
            selected = (try? await webView.evaluateJavaScript("window.picked ?? null")) as? [[String]]
            if selected == nil { try await Task.sleep(for: .milliseconds(25)) }
        } while selected == nil && ContinuousClock.now < resultDeadline
        XCTAssertNil(controller.window.attachedSheet)
        XCTAssertEqual(selected, [["封面 01.txt", "cover"], ["page 02.txt", "page"]])
    }
}
#endif
