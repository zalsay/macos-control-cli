import Foundation
import Darwin

@main struct RunnerPreparationMain {
    static func main() {
        do { print("PASS: \(try RunnerPreparationCases.run()) runner preparation checks") }
        catch { print("FAIL: \(error)"); exit(1) }
    }
}
