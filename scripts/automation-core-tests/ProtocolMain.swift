import Foundation
@main struct ProtocolMain {
    static func main() throws {
        let count = try AutomationProtocolCases.run()
        print("PASS: \(count) pure protocol checks")
    }
}
