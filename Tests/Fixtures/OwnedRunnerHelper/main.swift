import Foundation
import Darwin
@main struct OwnedRunnerHelper {
    static func main() {
        let env = ProcessInfo.processInfo.environment
        if let expected = env["OWNED_EXPECT_HOME"], env["SAFARIER_HOME"] != expected { exit(11) }
        if env["OWNED_EXPECT_BACKGROUND"] == "1" {
            let args = CommandLine.arguments
            guard args.contains("--background-automation"), let urlIndex = args.firstIndex(of: "--url"), urlIndex + 1 < args.count, args[urlIndex + 1] == "about:blank", args.contains("--profile"), !args.contains("--probe") else { exit(12) }
        }
        switch ProcessInfo.processInfo.environment["OWNED_FIXTURE_MODE"] {
        case "exit7": exit(7)
        case "wait":
            var byte: UInt8 = 0
            while true {
                let n = Darwin.read(STDIN_FILENO, &byte, 1)
                if n == 0 { exit(0) }
                if n < 0 && errno != EINTR { exit(2) }
            }
        default: exit(0)
        }
    }
}
