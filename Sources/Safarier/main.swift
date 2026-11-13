import Foundation
import SafarierCore
#if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
import Darwin

// Apply before selecting Manager or Runner so newly created data is private.
_ = umask(0o077)
#endif

// 同一个二进制三种身份：`run ...` 进入 Runner（一个 profile 一个进程），不带子命令进入图形管理器，
// 其它子命令是命令行 Manager。
let arguments = Array(CommandLine.arguments.dropFirst())

let role = ExecutableRole.resolve(arguments)
#if SAFARIER_BOUND_LOCAL_CANDIDATE
// These checks are negative routing restrictions, not identity or permission proof.
let bundleID = Bundle.main.bundleIdentifier
#if SAFARIER_INTERNAL_TEST_APP
let expectedMainBundleID = "sh.safarier.testing"
let expectedRunnerBundleID = "sh.safarier.testing.runner"
let expectedMainLeaf = "Safarier AI"
let expectedRunnerLeaf = "Safarier AI Browser"
#else
let expectedMainBundleID = "sh.safarier.boundcandidate"
let expectedRunnerBundleID = "sh.safarier.boundcandidate.runner"
let expectedMainLeaf = "Safarier"
let expectedRunnerLeaf = "SafarierRunner"
#endif
let executableLeaf = Bundle.main.executableURL?.lastPathComponent ?? URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
if ((bundleID == expectedRunnerBundleID || executableLeaf == expectedRunnerLeaf) && role != .runner) ||
   ((bundleID == expectedMainBundleID || executableLeaf == expectedMainLeaf) && role == .runner) {
    FileHandle.standardError.write(Data("candidate role mismatch\n".utf8))
    exit(1)
}
#endif

switch role {
case .runner:
    MainActor.assumeIsolated {
        RunnerMain.start(arguments: arguments)
    }
case .manager:
    MainActor.assumeIsolated {
        ManagerGUI.start()
    }
case .cli:
    let status = MainActor.assumeIsolated {
        ManagerCLI.run(arguments)
    }
    exit(status)
}
