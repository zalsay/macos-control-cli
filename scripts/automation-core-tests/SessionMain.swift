import Foundation
import Darwin
@main struct SessionMain {
    static func main() { do { print("PASS: \(try AutomationSessionCases.run()) session checks") } catch { print("FAIL: \(error)"); exit(1) } }
}
