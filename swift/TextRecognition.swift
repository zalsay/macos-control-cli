import Foundation
import Vision

struct ChromeTextObservation {
    let text: String
    let bounds: CGRect
    let confidence: Float
}

struct ChromeRecognizedText {
    let text: String
    let x: Int, y: Int, width: Int, height: Int
    let confidence: Float
    var centerX: Int { x + width / 2 }
    var centerY: Int { y + height / 2 }
    var json: [String: Any] {
        ["text": text, "bbox": ["x": x, "y": y, "width": width, "height": height],
         "center": ["x": centerX, "y": centerY], "confidence": confidence]
    }
}

struct ChromeTextResult {
    let status: String
    let items: [ChromeRecognizedText]
    let truncated: Bool
    static let unavailable = ChromeTextResult(status: "unavailable", items: [], truncated: false)
    var json: [String: Any] { ["status": status, "items": items.map(\.json), "truncated": truncated] }
}

func formatChromeText(_ observations: [ChromeTextObservation], width: Int, height: Int) -> ChromeTextResult {
    var items: [ChromeRecognizedText] = [], remaining = 8192, encodedBytes = 128, truncated = false
    for observation in observations {
        let b = observation.bounds
        guard !observation.text.isEmpty, observation.confidence.isFinite,
              (0...1).contains(observation.confidence),
              [b.minX, b.minY, b.maxX, b.maxY].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              b.width > 0, b.height > 0 else { continue }
        guard items.count < 128, remaining > 0 else { truncated = true; break }
        let text = String(String.UnicodeScalarView(observation.text.unicodeScalars.prefix(min(256, remaining))))
        if text.unicodeScalars.count < observation.text.unicodeScalars.count { truncated = true }
        // Vision 原点在左下；只转换坐标，不缩放或重采样截图。
        let x = Int(floor(b.minX * Double(width))), y = Int(floor((1 - b.maxY) * Double(height)))
        let right = min(width, Int(ceil(b.maxX * Double(width))))
        let bottom = min(height, Int(ceil((1 - b.minY) * Double(height))))
        guard right > x, bottom > y else { continue }
        let item = ChromeRecognizedText(text: text, x: x, y: y, width: right - x, height: bottom - y, confidence: observation.confidence)
        // JSON 转义也占协议字节；给帧元数据保留空间，不能只限制文字个数。
        guard let size = try? JSONSerialization.data(withJSONObject: item.json).count,
              encodedBytes + size + 1 <= 48 * 1024 else { truncated = true; break }
        items.append(item)
        encodedBytes += size + 1
        remaining -= text.unicodeScalars.count
    }
    items.sort { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
    return ChromeTextResult(status: "ok", items: items, truncated: truncated)
}

private final class ChromeTextJob {
    private let lock = NSLock()
    private var value = ChromeTextResult.unavailable
    let ready = DispatchSemaphore(value: 0)
    func finish(_ result: ChromeTextResult) { lock.lock(); value = result; lock.unlock(); ready.signal() }
    func result() -> ChromeTextResult { lock.lock(); defer { lock.unlock() }; return value }
}

final class ChromeTextRecognizer {
    typealias Analyze = (CGImage, VNRecognizeTextRequest) throws -> [ChromeTextObservation]
    private let analyze: Analyze
    private let lock = NSLock()
    private var running = false
    private let queue = DispatchQueue(label: "com.copis.chrome-cli.ocr", qos: .userInitiated)

    init(analyze: @escaping Analyze = { image, request in
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return ChromeTextObservation(text: candidate.string, bounds: observation.boundingBox, confidence: candidate.confidence)
        }
    }) { self.analyze = analyze }

    func recognize(_ image: CGImage, cancellation: InputCancellation, generation: UInt64,
                   timeout: TimeInterval = 3) throws -> ChromeTextResult {
        try cancellation.check(generation)
        lock.lock()
        // Vision 取消是协作式的；前次尚未退出时直接降级，避免积压图像和识别任务。
        if running { lock.unlock(); return .unavailable }
        running = true
        lock.unlock()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        let job = ChromeTextJob()
        queue.async {
            let result: ChromeTextResult
            do { result = formatChromeText(try self.analyze(image, request), width: image.width, height: image.height) }
            catch { result = .unavailable }
            self.lock.lock(); self.running = false; self.lock.unlock()
            job.finish(result)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        defer { request.cancel() }
        while true {
            try cancellation.check(generation)
            if job.ready.wait(timeout: .now() + 0.02) == .success {
                try cancellation.check(generation)
                return ProcessInfo.processInfo.systemUptime < deadline ? job.result() : .unavailable
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { return .unavailable }
        }
    }
}
