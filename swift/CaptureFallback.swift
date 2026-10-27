import Foundation
import ImageIO
import Darwin

// 只读采集允许切换后端；窗口身份、几何、权限和取消失败必须直接向上传递。
final class WindowCaptureStrategy {
    private(set) var usesFallback = false

    func capture<Image>(primary: () throws -> Image, fallback: () throws -> Image) throws -> Image {
        if usesFallback { return try fallback() }
        do { return try primary() }
        catch let failure as HelperFailure where ["CAPTURE_TIMEOUT", "CAPTURE_FAILED", "CAPTURE_WINDOW_LIST_TIMEOUT", "CAPTURE_IMAGE_TIMEOUT"].contains(failure.code) {
            let image = try fallback()
            // 同一个 Helper 后续观察不再反复等待已失效的系统服务；重启后重新尝试。
            usesFallback = true
            return image
        }
    }
}

func withWindowCaptureProcess<Value>(_ process: Process, cancellation: InputCancellation,
                                     generation: UInt64, timeout: TimeInterval = 6,
                                     cleanup: @escaping () -> Void = {}, readOutput: () throws -> Value) throws -> Value {
    try withProtectedNativeProcess(process, cancellation: cancellation, generation: generation,
                                   timeout: timeout,
                                   timeoutCode: "CAPTURE_FALLBACK_TIMEOUT",
                                   failureCode: "CAPTURE_FALLBACK_FAILED",
                                   failureMessage: "系统窗口截图后端未返回成功结果",
                                   timeoutMessage: "系统窗口截图后端响应超时",
                                   validate: { try cancellation.check(generation) },
                                   start: { try cancellation.effect(generation: generation) { try process.run() } },
                                   cleanup: cleanup, readOutput: readOutput)
}

// Chrome 启动与截图回退共用同一套有界子进程清理。StartupPermit 限定为 setup，
// 且每次轮询/启动都复核 generation、epoch 与“无活动 lease”条件。
func withCancellableSetupProcess<Value>(_ process: Process, cancellation: InputCancellation,
                                        permit: StartupPermit, timeout: TimeInterval = 20,
                                        timeoutCode: String, failureCode: String,
                                        failureMessage: String, timeoutMessage: String,
                                        cleanup: @escaping () -> Void = {},
                                        readOutput: () throws -> Value) throws -> Value {
    try withProtectedNativeProcess(process, cancellation: cancellation, generation: permit.generation,
                                   timeout: timeout, timeoutCode: timeoutCode,
                                   failureCode: failureCode, failureMessage: failureMessage,
                                   timeoutMessage: timeoutMessage,
                                   validate: { try cancellation.checkSetup(permit) },
                                   start: { try cancellation.setupEffect(permit: permit) { try process.run() } },
                                   cleanup: cleanup, readOutput: readOutput)
}

private func withProtectedNativeProcess<Value>(_ process: Process, cancellation: InputCancellation,
                                               generation: UInt64, timeout: TimeInterval,
                                               timeoutCode: String, failureCode: String,
                                               failureMessage: String, timeoutMessage: String,
                                               validate: () throws -> Void,
                                               start: () throws -> Void,
                                               cleanup: @escaping () -> Void,
                                               readOutput: () throws -> Value) throws -> Value {
    try validate()
    if process.standardInput == nil { process.standardInput = FileHandle.nullDevice }
    if process.standardOutput == nil { process.standardOutput = FileHandle.nullDevice }
    if process.standardError == nil { process.standardError = FileHandle.nullDevice }
    let lease = try cancellation.protectCapture(generation: generation) {
        // cancel ACK 前先终止/回收子进程，再清理私有资源。
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        cleanup()
    }
    defer { cancellation.finishCapture(lease) }
    do { try start() }
    catch let failure as HelperFailure { throw failure }
    catch { throw HelperFailure(code: failureCode, message: failureMessage) }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while process.isRunning {
        try validate()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw HelperFailure(code: timeoutCode, message: timeoutMessage)
        }
        Thread.sleep(forTimeInterval: 0.025)
    }
    try validate()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw HelperFailure(code: failureCode, message: failureMessage)
    }
    let value = try readOutput()
    try validate()
    return value
}

// 保留原生像素网格；1600×8192 是拒绝边界，不是重采样的目标尺寸。
func originalWindowPixelSize(width: Double, height: Double) throws -> (width: Int, height: Int) {
    guard width.isFinite, height.isFinite, width > 0, height > 0 else {
        throw HelperFailure(code: "IMAGE_GEOMETRY_CHANGED", message: "目标窗口原生像素尺寸无效")
    }
    let roundedWidth = width.rounded(), roundedHeight = height.rounded()
    guard abs(width - roundedWidth) < 0.001, abs(height - roundedHeight) < 0.001 else {
        throw HelperFailure(code: "IMAGE_GEOMETRY_CHANGED", message: "原生像素边界不完整，不能通过缩放凑整")
    }
    guard roundedWidth >= 1, roundedHeight >= 1, roundedWidth <= 1600, roundedHeight <= 8192 else {
        throw HelperFailure(code: "IMAGE_TOO_LARGE", message: "目标窗口原生截图超过 1600×8192 像素边界；不会缩放图片，请缩小目标窗口后重新观察")
    }
    let pixelWidth = Int(roundedWidth), pixelHeight = Int(roundedHeight)
    let (area, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
    guard !overflow, area <= 1600 * 8192 else {
        throw HelperFailure(code: "IMAGE_TOO_LARGE", message: "目标窗口原生截图超过 1600×8192 像素面积边界；不会缩放图片")
    }
    return (pixelWidth, pixelHeight)
}

func normalizeWindowCapture(url: URL, bounds: WindowBounds) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Double,
          let height = properties[kCGImagePropertyPixelHeight] as? Double,
          width.isFinite, height.isFinite, width > 0, height > 0 else {
        throw HelperFailure(code: "CAPTURE_FALLBACK_FAILED", message: "系统窗口截图后端未生成有效图像")
    }
    // 单窗口 -o 不带阴影；两轴必须使用同一个缩放比例，不允许把裁切图静默拉伸。
    let scale = width / bounds.width
    guard scale.isFinite, scale >= 1, height == bounds.height * scale else {
        throw HelperFailure(code: "IMAGE_GEOMETRY_CHANGED", message: "系统窗口截图区域与目标窗口不一致，请重新观察")
    }
    let size = try originalWindowPixelSize(width: width, height: height)
    // 临时PNG会在返回后清理，改由内存持有完整编码数据，避免CGImage懒加载再访问已删除文件。
    // 不创建thumbnail，也不改变原始像素宽高。
    let bytes: Data
    do { bytes = try Data(contentsOf: url) }
    catch { throw HelperFailure(code: "CAPTURE_FALLBACK_FAILED", message: "无法读取系统窗口截图原图") }
    guard let ownedSource = CGImageSourceCreateWithData(bytes as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(ownedSource, 0, nil),
          image.width == size.width, image.height == size.height else {
        throw HelperFailure(code: "IMAGE_GEOMETRY_CHANGED", message: "系统截图原图与像素元数据不一致")
    }
    return image
}

func captureSystemWindow(_ target: TargetWindow, bounds: WindowBounds, desktop: ChromeDesktop,
                         cancellation: InputCancellation, generation: UInt64) throws -> CGImage {
    try cancellation.check(generation)
    try desktop.requireScreenPermission()
    try desktop.verifyGeometry(target, expected: bounds)
    var template = Array((NSTemporaryDirectory() + "/copis-window-capture.XXXXXX").utf8CString)
    guard let directory = mkdtemp(&template) else {
        throw HelperFailure(code: "CAPTURE_FALLBACK_FAILED", message: "无法准备私有窗口截图目录")
    }
    let root = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("window.png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    // 固定系统路径、独立 argv；只截精确窗口，不截图整屏、不启动交互选择器、不写剪贴板。
    process.arguments = ["-x", "-o", "-a", "-l", String(target.windowId), "-t", "png", output.path]
    return try withWindowCaptureProcess(process, cancellation: cancellation, generation: generation, cleanup: {
        try? FileManager.default.removeItem(at: root)
    }, readOutput: {
        try desktop.verifyGeometry(target, expected: bounds)
        return try normalizeWindowCapture(url: output, bounds: bounds)
    })
}
