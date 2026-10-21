import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

private func require(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
private func expect(_ code: String, _ operation: () throws -> Void) {
    do { try operation(); require(false, "未拒绝：\(code)") }
    catch let failure as HelperFailure { require(failure.code == code, "错误码不符合预期：\(failure.code)") }
    catch { require(false, "出现非契约错误") }
}

var fallbackCalls = 0
let original = try WindowCaptureStrategy().capture(primary: { 42 }, fallback: { fallbackCalls += 1; return 99 })
require(original == 42 && fallbackCalls == 0, "成功截图不应重复采集")
for code in ["CAPTURE_TIMEOUT", "CAPTURE_FAILED", "CAPTURE_WINDOW_LIST_TIMEOUT", "CAPTURE_IMAGE_TIMEOUT"] {
    let value = try WindowCaptureStrategy().capture(primary: { throw HelperFailure(code: code, message: "fake") }, fallback: { 99 })
    require(value == 99, "系统截图故障未回退")
}
for code in ["CANCELLED", "WINDOW_UNAVAILABLE", "IMAGE_GEOMETRY_CHANGED", "SCREEN_PERMISSION_REQUIRED"] {
    expect(code) {
        let _: Int = try WindowCaptureStrategy().capture(primary: { throw HelperFailure(code: code, message: "fake") }, fallback: {
            require(false, "不得通过回退绕过权限、取消或窗口校验"); return 99
        })
    }
}
expect("CAPTURE_FALLBACK_FAILED") {
    let _: Int = try WindowCaptureStrategy().capture(primary: { throw HelperFailure(code: "CAPTURE_TIMEOUT", message: "fake") }, fallback: {
        throw HelperFailure(code: "CAPTURE_FALLBACK_FAILED", message: "fallback fake")
    })
}

// 同一 Helper 已成功回退后，不重复等待损坏的主后端；新策略会重新尝试主后端。
let strategy = WindowCaptureStrategy()
_ = try strategy.capture(primary: { throw HelperFailure(code: "CAPTURE_IMAGE_TIMEOUT", message: "fake") }, fallback: { 99 })
require(strategy.usesFallback, "成功回退后未保留后端选择")
let next = try strategy.capture(primary: { require(false, "后续观察再次调用失效后端"); return 0 }, fallback: { 100 })
require(next == 100 && !WindowCaptureStrategy().usesFallback, "重启后的主后端策略不正确")

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("copis-capture-fallback-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? FileManager.default.removeItem(at: scratch) }
guard let context = CGContext(data: nil, width: 2400, height: 1800, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
      let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(scratch.appendingPathComponent("fake.png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, image, nil)
require(CGImageDestinationFinalize(destination), "无法生成纯色测试图片")
// Given 原生截图超过已有1600上限，Then 必须拒绝，不能偷偷缩小后继续点击。
expect("IMAGE_TOO_LARGE") {
    _ = try normalizeWindowCapture(url: scratch.appendingPathComponent("fake.png"),
                                  bounds: WindowBounds(x: -100, y: 0, width: 1200, height: 900))
}
expect("IMAGE_GEOMETRY_CHANGED") {
    _ = try normalizeWindowCapture(url: scratch.appendingPathComponent("fake.png"),
                                  bounds: WindowBounds(x: 0, y: 0, width: 1200, height: 800))
}
expect("CAPTURE_FALLBACK_FAILED") {
    _ = try normalizeWindowCapture(url: scratch.appendingPathComponent("missing.png"),
                                  bounds: WindowBounds(x: 0, y: 0, width: 1200, height: 900))
}

// Given 普通及 Retina 原生尺寸在边界内，Then 像素宽高完全保留，不向1600放大或缩小。
let native = try originalWindowPixelSize(width: 1212, height: 1310)
require(native.width == 1212 && native.height == 1310, "1x原生像素应保持")
let retina = try originalWindowPixelSize(width: 800 * 2, height: 600 * 2)
require(retina.width == 1600 && retina.height == 1200, "2x原生像素应保持，不转成1x")
expect("IMAGE_TOO_LARGE") { _ = try originalWindowPixelSize(width: 1000 * 2, height: 800 * 2) }
expect("IMAGE_GEOMETRY_CHANGED") { _ = try originalWindowPixelSize(width: 801.5, height: 600) }
expect("IMAGE_GEOMETRY_CHANGED") { _ = try originalWindowPixelSize(width: .infinity, height: 600) }
expect("IMAGE_GEOMETRY_CHANGED") { _ = try originalWindowPixelSize(width: 0, height: 600) }
guard let smallContext = CGContext(data: nil, width: 1280, height: 960, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
      let small = smallContext.makeImage(),
      let smallOutput = CGImageDestinationCreateWithURL(scratch.appendingPathComponent("native.png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(smallOutput, small, nil)
require(CGImageDestinationFinalize(smallOutput), "无法生成原生尺寸测试图片")
let decoded = try normalizeWindowCapture(url: scratch.appendingPathComponent("native.png"),
                                        bounds: WindowBounds(x: 20, y: 40, width: 640, height: 480))
require(decoded.width == 1280 && decoded.height == 960, "系统回退必须保留原生像素，不输出缩略图")
// Given 回退临时PNG已清理，Then 返回的CGImage仍能完整编码为JPEG并重新解码。
try FileManager.default.removeItem(at: scratch.appendingPathComponent("native.png"))
let jpeg = NSMutableData()
guard let jpegOutput = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(jpegOutput, decoded, nil)
require(CGImageDestinationFinalize(jpegOutput), "清理临时PNG后原图必须仍可编码")
let jpegSource = CGImageSourceCreateWithData(jpeg as CFData, nil)
require(jpegSource.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil,
        "回退原图必须在临时文件清理后仍可完整解码，不能返回只有JPEG头的成功结果")


let cancellation = InputCancellation()
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/sleep")
process.arguments = ["10"]
expect("CAPTURE_FALLBACK_TIMEOUT") {
    try withWindowCaptureProcess(process, cancellation: cancellation, generation: cancellation.snapshot(), timeout: 0.1, readOutput: {})
}
let stopped = ProcessInfo.processInfo.systemUptime + 1
while process.isRunning && ProcessInfo.processInfo.systemUptime < stopped { Thread.sleep(forTimeInterval: 0.01) }
require(!process.isRunning, "超时截图子进程未清理")
let oldGeneration = cancellation.snapshot()
cancellation.cancel()
let unlaunched = Process()
unlaunched.executableURL = URL(fileURLWithPath: "/bin/sleep")
unlaunched.arguments = ["10"]
expect("CANCELLED") { try withWindowCaptureProcess(unlaunched, cancellation: cancellation, generation: oldGeneration, readOutput: {}) }
require(!unlaunched.isRunning, "取消 ACK 后仍启动截图子进程")

// Given 截图子进程已经运行，When cancel 返回 ACK，Then 子进程已退出且私有截图已删除。
let runningCancel = InputCancellation()
let runningGeneration = runningCancel.snapshot()
let runningProcess = Process()
runningProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
runningProcess.arguments = ["10"]
let privateCapture = scratch.appendingPathComponent("running-capture", isDirectory: true)
try FileManager.default.createDirectory(at: privateCapture, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
try Data("fake screenshot".utf8).write(to: privateCapture.appendingPathComponent("window.png"))
let completed = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    defer { completed.signal() }
    expect("CANCELLED") {
        try withWindowCaptureProcess(runningProcess, cancellation: runningCancel, generation: runningGeneration, cleanup: {
            try? FileManager.default.removeItem(at: privateCapture)
        }, readOutput: {})
    }
}
let launchDeadline = ProcessInfo.processInfo.systemUptime + 2
while !runningProcess.isRunning && ProcessInfo.processInfo.systemUptime < launchDeadline { Thread.sleep(forTimeInterval: 0.005) }
require(runningProcess.isRunning, "fake 截图进程没有启动")
runningCancel.cancel()
require(!runningProcess.isRunning, "取消 ACK 早于截图子进程退出")
require(!FileManager.default.fileExists(atPath: privateCapture.path), "取消 ACK 后私有截图仍然存在")
require(completed.wait(timeout: .now() + 2) == .success, "取消后截图动作未及时退出")

print("PASS: 截图回退 BDD：原像素1x/2x、超限拒绝而不缩放、后端策略、权限/几何失败关闭、Retina、超时终止、取消 ACK 后子进程已退出且文件已清理；未截图或发送输入")
