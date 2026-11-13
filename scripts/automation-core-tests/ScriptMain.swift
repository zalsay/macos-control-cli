import Foundation
import Darwin
@main struct ScriptMain {
    static func main() async {
        do { print("PASS: \(try await AutomationScriptCases.run()) script checks") }
        catch { print("FAIL: \(error)"); exit(1) }
    }
}
