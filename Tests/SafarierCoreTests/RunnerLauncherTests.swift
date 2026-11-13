import XCTest
@testable import SafarierCore

private final class RecordingSpawner: ProcessSpawning, @unchecked Sendable {
    struct Call: Equatable {
        var executableURL: URL
        var arguments: [String]
        var environment: [String: String]
        var logURL: URL?
    }
    private(set) var calls: [Call] = []

    func spawn(executableURL: URL, arguments: [String], environment: [String: String], logURL: URL?) throws -> Int32 {
        calls.append(Call(executableURL: executableURL, arguments: arguments, environment: environment, logURL: logURL))
        return 4242
    }
}

final class RunnerLauncherTests: XCTestCase {
    func testLaunchPassesSpecAsArgumentsEnvironmentAndPerProfileLog() throws {
        let spawner = RecordingSpawner()
        let exe = URL(fileURLWithPath: "/opt/Safarier")
        let logs = URL(fileURLWithPath: "/tmp/safarier-logs", isDirectory: true)
        let launcher = RunnerLauncher(executableURL: exe, spawner: spawner, logDirectory: logs)
        let spec = RunnerLaunchSpec(profileID: UUID(), languages: ["ja-JP"], timeZoneIdentifier: "Asia/Tokyo")

        let pid = try launcher.launch(spec, baseEnvironment: ["HOME": "/Users/x"])

        XCTAssertEqual(pid, 4242)
        XCTAssertEqual(spawner.calls.count, 1)
        let call = try XCTUnwrap(spawner.calls.first)
        XCTAssertEqual(call.executableURL, exe)
        XCTAssertEqual(call.arguments, spec.arguments())
        XCTAssertEqual(call.environment, ["HOME": "/Users/x", "TZ": "Asia/Tokyo"])
        XCTAssertEqual(call.logURL?.lastPathComponent, "\(spec.profileID.uuidString).log")
    }
}

extension RunnerLauncherTests {
    func testOldSpawnerDoesNotDiscardControlledInput() throws {
        let spawner = RecordingSpawner()
        let launcher = RunnerLauncher(spawner: spawner)
        let pair = try AutomationChannel.makePair()
        defer { pair.parent.close(); try? pair.child.close() }
        let spec = RunnerLaunchSpec(profileID: UUID(), startURL: URL(string: "about:blank"), backgroundAutomation: true)
        XCTAssertThrowsError(try launcher.launch(spec, controlInput: pair.child)) { XCTAssertEqual($0 as? ControlledLaunchError, .unsupportedControlledInput) }
        XCTAssertTrue(spawner.calls.isEmpty)
    }
}

#if SAFARIER_BOUND_LOCAL_CANDIDATE
extension RunnerLauncherTests {
    func testRegisteredInteractiveLaunchFailsClosedWithoutOwnedTransport() throws {
        let spawner = RecordingSpawner()
        let launcher = RunnerLauncher(spawner: spawner)
        let pair = try AutomationChannel.makePair()
        defer { pair.parent.close(); try? pair.child.close() }
        let normal = RunnerLaunchSpec(profileID: UUID())
        XCTAssertThrowsError(try launcher.launchOwnedInteractive(normal, registrationInput: pair.child)) {
            XCTAssertEqual($0 as? ControlledLaunchError, .unsupportedOwnedProcess)
        }
        var probe = normal
        probe.probe = true
        XCTAssertThrowsError(try launcher.launchOwnedInteractive(probe, registrationInput: pair.child)) {
            XCTAssertEqual($0 as? ControlledLaunchError, .incompatibleMode)
        }
        XCTAssertThrowsError(try launcher.launchOwnedInteractive(normal, registrationInput: .nullDevice))
        XCTAssertTrue(spawner.calls.isEmpty)
    }

    func testRegisteredLaunchMarkerSurvivesLanguageRelaunch() throws {
        var spec = RunnerLaunchSpec(profileID: UUID(), startURL: URL(string: "https://example.com"))
        spec.registeredInteractive = true
        XCTAssertEqual(try RunnerLaunchSpec.parse(spec.arguments()), spec)
        let relaunched = RunnerLaunchSpec.replacingAppleLanguages(["en-US"], in: spec.arguments())
        let parsed = try RunnerLaunchSpec.parse(relaunched)
        XCTAssertTrue(parsed.registeredInteractive)
        XCTAssertEqual(parsed.languages, ["en-US"])
        XCTAssertThrowsError(try RunnerLaunchSpec.parse(spec.arguments() + ["--probe"]))
        XCTAssertThrowsError(try RunnerLaunchSpec.parse(spec.arguments() + ["--registered-interactive"]))
    }
}
#endif
