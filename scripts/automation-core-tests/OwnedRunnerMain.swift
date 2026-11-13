import Foundation
import Darwin
@main struct OwnedRunnerMain {
    static func main() async { do { let env = ProcessInfo.processInfo.environment; print("PASS: \(try await OwnedRunnerCases.run(helper: URL(fileURLWithPath: env["OWNED_RUNNER_HELPER"]!), root: URL(fileURLWithPath: env["OWNED_RUNNER_FIXTURE"]!))) owned runner checks") } catch { print("FAIL: \(error)"); exit(1) } }
}
