import Foundation
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

// ScreenCaptureKit 回调有界等待；取消和 EOF 不会被系统回调无限拖住。
private final class CaptureResult<Value> {
    private let lock = NSLock()
    private var result: Result<Value, HelperFailure>?
    private let ready = DispatchSemaphore(value: 0)

    func finish(_ result: Result<Value, HelperFailure>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        lock.unlock()
        ready.signal()
    }

    func wait(cancellation: InputCancellation, generation: UInt64, stage: String) throws -> Value {
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while ready.wait(timeout: .now() + 0.025) == .timedOut {
            try cancellation.check(generation)
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw HelperFailure(code: stage == "window-list" ? "CAPTURE_WINDOW_LIST_TIMEOUT" : "CAPTURE_IMAGE_TIMEOUT", message: "系统截图服务 \(stage) 阶段响应超时")
            }
        }
        try cancellation.check(generation)
        lock.lock()
        let value = result
        lock.unlock()
        guard let value else { throw HelperFailure(code: "CAPTURE_FAILED", message: "系统截图服务未返回图像") }
        return try value.get()
    }
}

final class ChromeCapture {
    private let desktop: ChromeDesktop
    private let cancellation: InputCancellation
    private let captureStrategy = WindowCaptureStrategy()
    private let textRecognizer = ChromeTextRecognizer()

    init(desktop: ChromeDesktop, cancellation: InputCancellation) {
        self.desktop = desktop; self.cancellation = cancellation
    }

    func observe(_ target: TargetWindow, imagePath: String, generation: UInt64) throws -> [String: Any] {
        try cancellation.check(generation)
        try desktop.requireScreenPermission()
        let before = try desktop.window(target)
        desktop.updateOperation(target, label: chromeToastOperationLabel(action: "observe"), finished: false,
                                cancellation: cancellation, generation: generation)
        var completed = false
        defer { desktop.updateOperation(target, finished: true, succeeded: completed, cancellation: cancellation, generation: generation) }
        let image = try captureStrategy.capture(primary: {
            try screenCaptureKitImage(target, before: before, generation: generation)
        }, fallback: {
            return try captureSystemWindow(target, bounds: before.bounds, desktop: desktop,
                                           cancellation: cancellation, generation: generation)
        })
        let capturedAtMs = UInt64(Date().timeIntervalSince1970 * 1000)
        try desktop.verifyGeometry(target, expected: before.bounds)
        let jpeg = try encodeJPEG(image)
        // 从即将交给 Agent 的同一张 JPEG 识别，不另截图，也不改变像素尺寸。
        var ocr = ChromeTextResult.unavailable
        if let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
           let deliveredImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            ocr = try textRecognizer.recognize(deliveredImage, cancellation: cancellation, generation: generation)
        }
        // 编码期间也可能有移动/缩放，落盘前再核对一次，失败不留下错误坐标的图像。
        try cancellation.check(generation)
        try desktop.verifyGeometry(target, expected: before.bounds)
        try saveExclusive(jpeg, path: imagePath)
        do {
            try cancellation.check(generation)
            try desktop.verifyGeometry(target, expected: before.bounds)
            // 复用这次观察取得的标题；只更新已有控制条，不启动控制或恢复已关闭提示。
            try desktop.updateOperationToastTitle(target, title: before.title, cancellation: cancellation, generation: generation)
        } catch {
            // 此文件由 O_EXCL 新建，失败时只移除自己的图像。
            _ = unlink(imagePath)
            throw error
        }
        completed = true
        return ["imagePath": imagePath, "width": image.width, "height": image.height,
                "bounds": before.bounds.json, "capturedAtMs": capturedAtMs,
                "coordinateSpace": "frame-pixels", "imageTransform": "crop-only", "captureBackend": captureStrategy.usesFallback ? "screencapture" : "screen-capture-kit", "ocr": ocr.json]
    }

    private func screenCaptureKitImage(_ target: TargetWindow, before: ChromeWindow, generation: UInt64) throws -> CGImage {
        let contentResult = CaptureResult<SCShareableContent>()
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, _ in
            if let content { contentResult.finish(.success(content)) }
            else { contentResult.finish(.failure(HelperFailure(code: "CAPTURE_FAILED", message: "无法获取系统可共享窗口列表"))) }
        }
        let content = try contentResult.wait(cancellation: cancellation, generation: generation, stage: "window-list")
        guard let window = content.windows.first(where: {
            $0.windowID == target.windowId && $0.owningApplication?.processID == target.pid &&
            $0.owningApplication?.bundleIdentifier == before.target.bundleId && $0.windowLayer == 0 && $0.isOnScreen
        }) else { throw HelperFailure(code: "WINDOW_UNAVAILABLE", message: "指定应用窗口不在可截图列表中") }
        let frame = window.frame
        let snapshot = WindowBounds(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)
        guard before.bounds.matches(snapshot) else { throw geometryFailure() }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        // 去掉阴影后，截图内容必须与返回的完整逻辑窗口区域一致，拒绝静默拉伸/裁剪。
        guard filter.contentRect.width == before.bounds.width, filter.contentRect.height == before.bounds.height else {
            throw geometryFailure()
        }
        let nativeScale = Double(filter.pointPixelScale)
        guard nativeScale.isFinite, nativeScale > 0 else {
            throw HelperFailure(code: "CAPTURE_FAILED", message: "系统返回了无效的图像缩放比例")
        }
        let size = try originalWindowPixelSize(width: before.bounds.width * nativeScale,
                                               height: before.bounds.height * nativeScale)
        let width = size.width, height = size.height
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.showsCursor = false
        config.scalesToFit = false
        config.preservesAspectRatio = true
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        config.shouldBeOpaque = true
        try desktop.verifyGeometry(target, expected: before.bounds)
        try cancellation.check(generation)
        let imageResult = CaptureResult<CGImage>()
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
            if let image { imageResult.finish(.success(image)) }
            else { imageResult.finish(.failure(HelperFailure(code: "CAPTURE_FAILED", message: "系统未能捕获目标 Chrome 窗口"))) }
        }
        let image = try imageResult.wait(cancellation: cancellation, generation: generation, stage: "capture-image")
        guard image.width == width, image.height == height else { throw geometryFailure() }
        return image
    }

    private func geometryFailure() -> HelperFailure {
        HelperFailure(code: "IMAGE_GEOMETRY_CHANGED", message: "截图期间窗口几何或图像区域发生变化，请重新观察")
    }

    private func encodeJPEG(_ image: CGImage) throws -> Data {
        for quality in [0.88, 0.72, 0.55, 0.38, 0.22, 0.1, 0.04] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { break }
            CGImageDestinationAddImage(destination, image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), data.length > 0, data.length < 1_048_576 { return data as Data }
        }
        throw HelperFailure(code: "IMAGE_TOO_LARGE", message: "无法在安全大小限制内编码 JPEG 图像")
    }

    private func saveExclusive(_ data: Data, path: String) throws {
        // 不覆盖文件、不跟随末级符号链接、权限仅当前用户可读写。
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw HelperFailure(code: errno == EEXIST ? "OUTPUT_EXISTS" : "OUTPUT_WRITE_FAILED",
                                message: "无法新建截图文件；请使用可写目录下尚不存在的绝对路径")
        }
        var complete = false
        defer {
            _ = close(fd)
            if !complete { _ = unlink(path) }
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw HelperFailure(code: "OUTPUT_WRITE_FAILED", message: "截图文件写入失败") }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw HelperFailure(code: "OUTPUT_WRITE_FAILED", message: "截图文件写入失败") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw HelperFailure(code: "OUTPUT_WRITE_FAILED", message: "截图文件写入未完成") }
        complete = true
    }
}
