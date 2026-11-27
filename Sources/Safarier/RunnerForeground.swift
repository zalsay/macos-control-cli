import AppKit
import Foundation
import SafarierCore

/// Validates the profile lock and exact packaged Runner identity before activation.
@MainActor
enum RunnerForeground {
    enum ActivationResult {
        case verified(pid: Int32)
        case requestedButUnverified
    }

    enum Failure: LocalizedError {
        case notRunning
        case changedDuringActivation
        case unexpectedRunner
        case activationRefused

        var errorDescription: String? {
            switch self {
            case .notRunning:
                return "profile 没有正在运行的 Runner"
            case .changedDuringActivation:
                return "Runner 在激活期间退出或发生变化"
            case .unexpectedRunner:
                return "锁文件 PID 对应的进程不是当前安装包中的 Runner"
            case .activationRefused:
                return "macOS 拒绝了 Runner 激活请求"
            }
        }
    }

    static func activate(
        profileID: UUID,
        workspace: SafarierWorkspace,
        verificationTimeout: TimeInterval = 1.25
    ) throws -> ActivationResult {
        guard workspace.isRunning(profileID), let pid = workspace.runnerPID(profileID), pid > 0 else {
            throw Failure.notRunning
        }

        let expectedExecutable = RunnerLauncher.defaultRunnerExecutableURL()
        guard validatedApplication(pid: pid, expectedExecutable: expectedExecutable) != nil else {
            throw Failure.unexpectedRunner
        }

        // Re-read the held lock and PID immediately before sending the activation request.
        guard workspace.isRunning(profileID), workspace.runnerPID(profileID) == pid else {
            throw Failure.changedDuringActivation
        }
        guard let app = validatedApplication(pid: pid, expectedExecutable: expectedExecutable) else {
            throw Failure.unexpectedRunner
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            return .verified(pid: pid)
        }
        guard app.activate(options: [.activateAllWindows]) else { throw Failure.activationRefused }

        let deadline = Date().addingTimeInterval(max(0, verificationTimeout))
        repeat {
            guard workspace.isRunning(profileID), workspace.runnerPID(profileID) == pid else {
                throw Failure.changedDuringActivation
            }
            guard validatedApplication(pid: pid, expectedExecutable: expectedExecutable) != nil else {
                throw Failure.unexpectedRunner
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                return .verified(pid: pid)
            }
            guard Date() < deadline else { break }
            _ = RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05)))
        } while true

        return .requestedButUnverified
    }

    static func isExpectedRunnerExecutable(_ executable: URL, expected: URL) -> Bool {
        executable.standardizedFileURL.resolvingSymlinksInPath().path ==
            expected.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func validatedApplication(pid: Int32, expectedExecutable: URL) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              let executable = app.executableURL,
              isExpectedRunnerExecutable(executable, expected: expectedExecutable) else { return nil }
        return app
    }
}
