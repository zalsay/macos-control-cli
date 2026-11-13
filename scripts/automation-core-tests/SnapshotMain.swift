import Foundation
import Darwin
@main struct SnapshotMain {
    static func main() {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            print("PASS: \(try AutomationSnapshotCases.run(base: root)) snapshot checks")
        } catch { print("FAIL: \(error)"); exit(1) }
    }
}
