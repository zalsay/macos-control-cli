import Foundation
@main struct ControlledRunnerMain {
    static func main() async throws { print("PASS: \(try await ControlledRunnerCases.run()) controlled runner checks") }
}
