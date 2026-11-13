import Foundation
@main struct Main {
    static func main() async {
        do { print("PASS: \(try await OwnedChildLifecycleCases.run(helper: URL(fileURLWithPath: ProcessInfo.processInfo.environment["OWNED_CHILD_HELPER"]!))) lifecycle checks") }
        catch { print("FAIL: \(error)"); exit(1) }
    }
}
