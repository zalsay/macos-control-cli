import Foundation
import Darwin

@main struct NonInteractiveCredentialMain {
    static func main() {
        do { print("PASS: \(try NonInteractiveCredentialCases.run()) non-interactive credential checks") }
        catch { print("FAIL: \(error)"); exit(1) }
    }
}
