import XCTest
@testable import Safarier

/// 命令行 `--lang` / `--tz` 的取值：proxy / auto 跟随代理，system / none 跟随系统，其它照原样。
@MainActor
final class ManagerCLITests: XCTestCase {
    func testLanguageOption() {
        for raw in ["proxy", "auto", "PROXY"] {
            let option = ManagerCLI.parseLanguageOption(raw)
            XCTAssertTrue(option.follow, raw)
            XCTAssertEqual(option.languages, [], raw)
        }
        for raw in ["system", "none"] {
            let option = ManagerCLI.parseLanguageOption(raw)
            XCTAssertFalse(option.follow, raw)
            XCTAssertEqual(option.languages, [], raw)
        }
        let custom = ManagerCLI.parseLanguageOption("th-TH, th")
        XCTAssertFalse(custom.follow)
        XCTAssertEqual(custom.languages, ["th-TH", "th"])
    }

    func testTimeZoneOption() {
        for raw in ["proxy", "auto"] {
            let option = ManagerCLI.parseTimeZoneOption(raw)
            XCTAssertTrue(option.follow, raw)
            XCTAssertNil(option.identifier, raw)
        }
        for raw in ["system", "none"] {
            let option = ManagerCLI.parseTimeZoneOption(raw)
            XCTAssertFalse(option.follow, raw)
            XCTAssertNil(option.identifier, raw)
        }
        let custom = ManagerCLI.parseTimeZoneOption("Asia/Bangkok")
        XCTAssertFalse(custom.follow)
        XCTAssertEqual(custom.identifier, "Asia/Bangkok")
    }

    func testForegroundRequiresExactlyOneUUID() throws {
        let id = UUID()
        XCTAssertEqual(try ManagerCLI.foregroundProfileID([id.uuidString]), id)

        for arguments in [[], [id.uuidString, "extra"], ["not-a-uuid"]] {
            XCTAssertThrowsError(try ManagerCLI.foregroundProfileID(arguments), "arguments: \(arguments)")
        }
    }

    func testForegroundRunnerExecutableIdentityUsesCanonicalPaths() {
        let expected = URL(fileURLWithPath: "/tmp/Safarier AI Browser.app/Contents/MacOS/Safarier AI Browser")
        XCTAssertTrue(RunnerForeground.isExpectedRunnerExecutable(expected, expected: expected))
        XCTAssertFalse(
            RunnerForeground.isExpectedRunnerExecutable(
                URL(fileURLWithPath: "/tmp/other-runner"), expected: expected
            )
        )
    }
}
