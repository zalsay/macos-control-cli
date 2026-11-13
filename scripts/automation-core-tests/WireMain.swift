import Foundation
import Darwin
@main struct WireMain {
    static func main() async {
        do { print("PASS: \(try await AutomationWireCases.run()) wire checks") }
        catch { print("FAIL: \(error)"); exit(1) }
    }
}
