import Foundation
import Darwin
@main struct RunnerServiceMain {
    static func main() async { do { let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RUNNER_SERVICE_FIXTURE"]!); print("PASS: \(try await RunnerAutomationServiceCases.run(base: base)) service checks") } catch { print("FAIL: \(error)"); exit(1) } }
}
