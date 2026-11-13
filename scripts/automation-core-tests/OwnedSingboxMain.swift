import Foundation
@main struct Main {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        let count = try await OwnedSingboxCases.run(helper: URL(fileURLWithPath: env["OWNED_SINGBOX_HELPER"]!), root: URL(fileURLWithPath: env["OWNED_SINGBOX_FIXTURE"]!))
        print("OwnedSingbox: \(count) checks passed")
    }
}
