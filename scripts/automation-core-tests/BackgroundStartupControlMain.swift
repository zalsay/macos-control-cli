import Foundation
import Darwin

@main struct BackgroundStartupControlMain {
    static func main() async {
        do { print("PASS: \(try await BackgroundStartupControlCases.run()) background startup control checks") }
        catch { print("FAIL: \(error)"); exit(1) }
    }
}
