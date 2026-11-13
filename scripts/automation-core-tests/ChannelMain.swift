import Foundation
@main struct ChannelMain {
    static func main() async throws {
        let count = try await AutomationChannelCases.run()
        print("PASS: \(count) pure channel checks")
    }
}
