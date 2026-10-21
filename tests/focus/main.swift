import Foundation
import AppKit

// 显式运行的真实桌面回归：只切换指定应用焦点，不截图、不创建或发送输入事件。
setbuf(stdout, nil)
guard CommandLine.arguments.count == 3,
      let windowID = UInt32(CommandLine.arguments[1]), windowID > 0,
      let otherPID = Int32(CommandLine.arguments[2]), otherPID > 0 else {
    fputs("用法：focus-tests <Chrome 窗口 ID> <用于失焦验证的其他应用 PID>\n", stderr)
    exit(2)
}
_ = NSApplication.shared.setActivationPolicy(.accessory)
let desktop = ChromeDesktop()

func require(_ value: Bool, _ message: String) throws {
    if !value { throw HelperFailure(code: "TEST_FAILED", message: message) }
}

func expectFailure(_ code: String, _ operation: () throws -> Void) throws {
    do {
        try operation()
        throw HelperFailure(code: "TEST_FAILED", message: "应拒绝输入前校验：\(code)")
    } catch let failure as HelperFailure where failure.code == code { }
}

DispatchQueue.global().async {
    do {
        guard let window = desktop.windows().first(where: { $0.target.windowId == windowID }),
              otherPID != window.target.pid,
              let other = NSRunningApplication(processIdentifier: otherPID), !other.isTerminated else {
            throw HelperFailure.invalidArgument
        }
        let target = window.target
        let cancellation = InputCancellation()
        let generation = cancellation.snapshot()
        // Given 系统焦点查询可能无值，When 已激活精确 Chrome 窗口，Then 仍可验证真实前台和窗口。
        try desktop.activate(target, expected: window.bounds, cancellation: cancellation, generation: generation)
        try desktop.verifyFocus(target, expected: window.bounds)
        print("PASS: 目标窗口激活后焦点校验通过")

        if let another = desktop.windows().first(where: { $0.target.windowId != target.windowId }) {
            // Given 同一 Chrome 的另一窗口，Then 不能把应用前台误认为该窗口有焦点。
            try expectFailure("FOCUS_LOST") { try desktop.verifyFocus(another.target, expected: another.bounds) }
            print("PASS: 拒绝同一 Chrome 中未聚焦的其他窗口")
        }
        let changed = WindowBounds(x: window.bounds.x, y: window.bounds.y,
                                   width: window.bounds.width + 1, height: window.bounds.height)
        try expectFailure("IMAGE_GEOMETRY_CHANGED") { try desktop.verifyFocus(target, expected: changed) }
        print("PASS: 拒绝与当前窗口不一致的帧几何")

        // Given 另一个真实应用成为前台，Then 即使 Chrome 仍保留 focusedWindow 也必须拒绝。
        try require(onMain { other.activate(options: []) }, "无法激活指定的其他应用")
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while onMain({ NSWorkspace.shared.frontmostApplication?.processIdentifier }) != otherPID {
            try require(ProcessInfo.processInfo.systemUptime < deadline, "其他应用未成为前台")
            Thread.sleep(forTimeInterval: 0.025)
        }
        try expectFailure("FOCUS_LOST") { try desktop.verifyFocus(target, expected: window.bounds) }
        print("PASS: 拒绝已失去前台的目标窗口；全程未发送输入")
        exit(0)
    } catch let failure as HelperFailure {
        fputs("FAIL: \(failure.code): \(failure.message)\n", stderr)
        exit(1)
    } catch {
        fputs("FAIL: \(error)\n", stderr)
        exit(1)
    }
}
let keepAlive = Port()
RunLoop.main.add(keepAlive, forMode: .default)
RunLoop.main.run()
