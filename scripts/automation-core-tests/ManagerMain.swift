import Foundation
import Darwin
@main struct ManagerMain {
    static func main() async {
        do { print("PASS: \(try await AutomationManagerCases.run()) manager checks") }
        catch { print("FAIL: \(error)"); exit(1) }
    }
}
