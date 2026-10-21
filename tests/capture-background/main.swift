import AppKit

// 显式只读真实回归：模拟截图服务故障，验证生产回退后端，不查看截图、不发送输入。
setbuf(stdout, nil)
_ = NSApplication.shared.setActivationPolicy(.accessory)
guard CommandLine.arguments.count == 2, let windowID = UInt32(CommandLine.arguments[1]), windowID > 0 else { exit(2) }
let desktop = ChromeDesktop()
let initialFrontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
DispatchQueue.global().async {
    do {
        guard let target = desktop.windows().first(where: { $0.target.windowId == windowID }) else {
            throw HelperFailure(code: "WINDOW_UNAVAILABLE", message: "测试目标窗口不可用")
        }
        let cancellation = InputCancellation()
        let generation = cancellation.snapshot()
        let strategy = WindowCaptureStrategy()
        for index in 1...2 {
            let started = ProcessInfo.processInfo.systemUptime
            let image = try strategy.capture(primary: {
                if index == 2 { throw HelperFailure(code: "TEST_FAILED", message: "重复调用已失效的截图后端") }
                throw HelperFailure(code: "CAPTURE_IMAGE_TIMEOUT", message: "模拟系统截图服务超时")
            }, fallback: {
                try captureSystemWindow(target.target, bounds: target.bounds, desktop: desktop,
                                        cancellation: cancellation, generation: generation)
            })
            guard max(image.width, image.height) <= 1600,
                  onMain({ NSWorkspace.shared.frontmostApplication?.processIdentifier }) == initialFrontPID else {
                throw HelperFailure(code: "TEST_FAILED", message: "回退截图尺寸异常或意外改变前台")
            }
            print("PASS: 只读回退 \(index)，尺寸 \(image.width)x\(image.height)，耗时 \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))ms，前台未改变")
        }
        exit(0)
    } catch let error as HelperFailure { fputs("FAIL: \(error.code): \(error.message)\n", stderr); exit(1) }
    catch { fputs("FAIL: 只读回退回归异常\n", stderr); exit(1) }
}
let keepAlive = Port()
RunLoop.main.add(keepAlive, forMode: .default)
RunLoop.main.run()
