import Darwin
import Foundation
import ImageIO
import Vision
import SafarierCore

final class ControlOCR: @unchecked Sendable {
    static let shared = ControlOCR()
    private let lock = NSLock()
    private var busy = false
    private let queue = DispatchQueue(label: "sh.safarier.control.ocr", qos: .userInitiated)
    private final class Job: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var output = SemanticOCRResult.unavailable
        func finish(_ result: SemanticOCRResult) { lock.lock(); output=result; lock.unlock(); semaphore.signal() }
        func value() -> SemanticOCRResult { lock.lock(); defer { lock.unlock() }; return output }
    }
    func recognize(path: String, viewport: AutomationViewport) async -> SemanticOCRResult {
        await Task.detached { [self] in recognizeSync(path: path, viewport: viewport) }.value
    }
    private func recognizeSync(path: String, viewport: AutomationViewport) -> SemanticOCRResult {
        let started = DispatchTime.now().uptimeNanoseconds
        func diagnostic(_ stage: String, error: NSError? = nil) {
            let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            var detail = ""
            if let error {
                let domain = error.domain.utf8.count <= 128 && error.domain.utf8.allSatisfy { (45...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 } ? error.domain : "other"
                detail = " domain=\(domain) code=\(error.code)"
            }
            fputs("OCR_DIAG stage=\(stage) elapsedMs=\(elapsed)\(detail)\n", stderr)
        }
        lock.lock(); guard !busy else { lock.unlock(); diagnostic("busy"); return .unavailable }; busy=true; lock.unlock()
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { lock.lock(); busy=false; lock.unlock(); diagnostic("file_open_failed"); return .unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), (info.st_mode & 0o777) == 0o600, info.st_nlink == 1, info.st_size > 0, info.st_size <= AutomationLimits.screenshotMaxBytes else {
            close(fd); lock.lock(); busy=false; lock.unlock(); diagnostic("file_stat_failed"); return .unavailable
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var data = Data(), after = stat()
        do {
            while data.count <= AutomationLimits.screenshotMaxBytes {
                let chunk = try file.read(upToCount: min(65536, AutomationLimits.screenshotMaxBytes + 1 - data.count)) ?? Data()
                if chunk.isEmpty { break }; data.append(chunk)
            }
        } catch { lock.lock(); busy=false; lock.unlock(); diagnostic("file_read_failed"); return .unavailable }
        guard data.count == info.st_size, data.count <= AutomationLimits.screenshotMaxBytes,
              fstat(fd, &after) == 0, after.st_dev == info.st_dev, after.st_ino == info.st_ino,
              after.st_size == info.st_size, after.st_uid == info.st_uid, after.st_mode == info.st_mode,
              after.st_nlink == info.st_nlink, after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else {
            lock.lock(); busy=false; lock.unlock(); diagnostic("file_identity_failed"); return .unavailable
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == viewport.pixelWidth, height == viewport.pixelHeight else {
            lock.lock(); busy=false; lock.unlock(); diagnostic("metadata_failed"); return .unavailable
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == width, image.height == height else {
            lock.lock(); busy=false; lock.unlock(); diagnostic("decode_failed"); return .unavailable
        }
        let job = Job(), request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        queue.async { [self] in
            diagnostic("vision_start")
            var output = SemanticOCRResult.unavailable
            do {
                try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
                var items: [SemanticOCRItem] = [], remaining = 8192, bytes = 128, truncated = false
                for observation in request.results ?? [] {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let b = observation.boundingBox, confidence = Double(candidate.confidence)
                    guard !candidate.string.isEmpty, confidence.isFinite, (0...1).contains(confidence),
                          [b.minX,b.minY,b.maxX,b.maxY].allSatisfy({ $0.isFinite && (0...1).contains($0) }), b.width > 0, b.height > 0 else { continue }
                    guard items.count < 128, remaining > 0 else { truncated=true; break }
                    let text = String(String.UnicodeScalarView(candidate.string.unicodeScalars.prefix(min(256,remaining))))
                    if text.unicodeScalars.count < candidate.string.unicodeScalars.count { truncated=true }
                    let x = Int(floor(b.minX * Double(image.width))), y = Int(floor((1-b.maxY) * Double(image.height)))
                    let right = min(image.width,Int(ceil(b.maxX * Double(image.width))))
                    let bottom = min(image.height,Int(ceil((1-b.minY) * Double(image.height))))
                    guard right > x, bottom > y else { continue }
                    let item = SemanticOCRItem(text:text,x:x,y:y,width:right-x,height:bottom-y,confidence:confidence)
                    guard let size = try? JSONEncoder().encode(item).count, bytes + size + 1 <= 48*1024 else { truncated=true; break }
                    items.append(item); bytes += size+1; remaining -= text.unicodeScalars.count
                }
                items.sort { $0.bbox.y == $1.bbox.y ? $0.bbox.x < $1.bbox.x : $0.bbox.y < $1.bbox.y }
                output = SemanticOCRResult(status:"ok",items:items,truncated:truncated)
                diagnostic("vision_finish")
            } catch { diagnostic("vision_error", error: error as NSError) }
            self.lock.lock(); self.busy=false; self.lock.unlock(); job.finish(output)
        }
        defer { request.cancel() }
        guard job.semaphore.wait(timeout: .now()+5) == .success else { diagnostic("vision_timeout"); return .unavailable }
        return job.value()
    }
}
