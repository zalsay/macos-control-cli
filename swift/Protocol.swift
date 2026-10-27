import Foundation
import CoreGraphics
import Darwin

struct HelperFailure: Error {
    let code: String
    let message: String

    static let invalidArgument = HelperFailure(code: "INVALID_ARGUMENT", message: "请求参数不符合原生动作契约")
    static let userPaused = HelperFailure(code: "USER_PAUSED", message: "桌面输入已暂停，请点击屏幕上方控制条的继续按钮并等待 3 秒倒计时；暂停不会自动恢复，也不会重放旧输入")
    static let cancelled = HelperFailure(code: "CANCELLED", message: "操作已取消，请重新提交")
}

struct WindowBounds {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var json: [String: Any] { ["x": x, "y": y, "width": width, "height": height] }

    func matches(_ other: WindowBounds) -> Bool {
        // 不接受可累积的位移容差；同一 CG 窗口快照的坐标应当一致。
        x == other.x && y == other.y && width == other.width && height == other.height
    }

    func contains(_ point: CGPoint) -> Bool {
        point.x >= x && point.y >= y && point.x < x + width && point.y < y + height
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    init(json: [String: Any]) throws {
        guard Set(json.keys) == Set(["x", "y", "width", "height"]) else { throw HelperFailure.invalidArgument }
        x = try finiteNumber(json["x"])
        y = try finiteNumber(json["y"])
        width = try finiteNumber(json["width"])
        height = try finiteNumber(json["height"])
        guard width > 0, height > 0 else { throw HelperFailure.invalidArgument }
    }
}

struct TargetWindow {
    let windowId: CGWindowID
    let pid: pid_t
    var bundleId: String? = nil
}

// 解析完成才进入系统 API：非法请求永远不会触发授权、激活或输入。
struct NativeRequest {
    let id: String
    let action: String
    var target: TargetWindow?
    var expectedBounds: WindowBounds?
    var point: CGPoint?
    var clickCount = 1
    var deltaY = 0
    var text = ""
    var key = ""
    var imagePath = ""
    var filePath = ""
    var url = "about:blank"
    var profile: String?
    var profileMarkerPath: String?
    var maxWidthPx = 1600
    var requestPermissions = false
    var prepareToast = false
    // 仅由 stdin 接收线程签发，协议请求不能自行指定或绕过暂停前的排队代次。
    var inputEpoch: UInt64?

    static func decode(_ json: [String: Any], scope: DesktopScope = .chrome) throws -> NativeRequest {
        guard let id = json["id"] as? String, validRequestID(id),
              let action = json["action"] as? String else {
            throw HelperFailure(code: "INVALID_REQUEST", message: "请求必须包含有效的字符串 id 和 action")
        }
        var fields: [String: Set<String>] = [
            "permissions": ["request"], "windows": [], "cancel": [],
            "window": ["windowId", "pid", "prepareToast"],
            "observe": ["windowId", "pid", "imagePath", "maxEdge"],
            "chrome-start": ["url", "maxWidthPx", "profile", "profileMarkerPath"],
            "click": ["windowId", "pid", "expectedBounds", "screenX", "screenY", "clickCount"],
            "scroll": ["windowId", "pid", "expectedBounds", "screenX", "screenY", "deltaY"],
            "type": ["windowId", "pid", "expectedBounds", "text"],
            "press": ["windowId", "pid", "expectedBounds", "key"],
            "select-file": ["windowId", "pid", "path"],
        ]
        if scope == .desktop { fields["apps"] = [] }
        for key in Array(fields.keys) where fields[key]?.contains("windowId") == true {
            fields[key]?.insert("bundleId")
        }
        guard let allowed = fields[action] else {
            throw HelperFailure(code: "UNKNOWN_ACTION", message: "不支持该原生动作")
        }
        guard Set(json.keys).isSubset(of: allowed.union(["id", "action"])) else {
            throw HelperFailure.invalidArgument
        }
        var request = NativeRequest(id: id, action: action)
        if action == "permissions", let value = json["request"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw HelperFailure.invalidArgument
            }
            request.requestPermissions = number.boolValue
        }
        if let value = json["prepareToast"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw HelperFailure.invalidArgument }
            request.prepareToast = number.boolValue
        }
        if allowed.contains("windowId") {
            request.target = TargetWindow(
                windowId: CGWindowID(try integer(json["windowId"], range: 1...Int64(UInt32.max))),
                pid: pid_t(try integer(json["pid"], range: 1...Int64(Int32.max)))
            )
            if let value = json["bundleId"] {
                guard let bundle = value as? String, !bundle.isEmpty, bundle.utf8.count <= 255,
                      !bundle.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      scope == .desktop || bundle == "com.google.Chrome" else { throw HelperFailure.invalidArgument }
                request.target?.bundleId = bundle
            } else if scope == .desktop { throw HelperFailure.invalidArgument }
        }
        if allowed.contains("expectedBounds") {
            guard let bounds = json["expectedBounds"] as? [String: Any] else { throw HelperFailure.invalidArgument }
            request.expectedBounds = try WindowBounds(json: bounds)
        }
        if action == "click" || action == "scroll" {
            let point = CGPoint(x: try finiteNumber(json["screenX"]), y: try finiteNumber(json["screenY"]))
            guard request.expectedBounds?.contains(point) == true else { throw HelperFailure.invalidArgument }
            request.point = point
        }
        switch action {
        case "click": request.clickCount = Int(try integer(json["clickCount"], range: 1...2))
        case "scroll":
            request.deltaY = Int(try integer(json["deltaY"], range: -1200...1200))
            guard request.deltaY != 0 else { throw HelperFailure.invalidArgument }
        case "type":
            guard let text = json["text"] as? String, (1...4096).contains(text.unicodeScalars.count),
                  !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                throw HelperFailure.invalidArgument
            }
            request.text = text
        case "press":
            guard let key = json["key"] as? String, allowedKeys[key] != nil else { throw HelperFailure.invalidArgument }
            request.key = key
        case "select-file":
            guard let path = json["path"] as? String, path.hasPrefix("/"), !path.hasSuffix("/"),
                  path.utf8.count <= 4096, !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
                throw HelperFailure.invalidArgument
            }
            request.filePath = path
        case "observe":
            guard let path = json["imagePath"] as? String, path.hasPrefix("/"), !path.hasSuffix("/"),
                  path.utf8.count <= 4096, !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
                throw HelperFailure.invalidArgument
            }
            if let edge = json["maxEdge"] { _ = try integer(edge, range: 1600...1600) }
            request.imagePath = path
        case "chrome-start":
            if let raw = json["profile"] {
                guard let name = raw as? String, validChromeProfileName(name) else { throw HelperFailure.invalidArgument }
                request.profile = name
            }
            if let raw = json["profileMarkerPath"] {
                guard request.profile != nil, let path = raw as? String, validChromeProfileMarkerPath(path) else { throw HelperFailure.invalidArgument }
                request.profileMarkerPath = path
            }
            if request.profile != nil && request.profileMarkerPath == nil { throw HelperFailure.invalidArgument }
            if let value = json["url"] {
                guard let url = value as? String, validChromeStartURL(url) else {
                    throw HelperFailure.invalidArgument
                }
                request.url = url
            }
            if let value = json["maxWidthPx"] {
                request.maxWidthPx = Int(try integer(value, range: 400...1600))
            }
        default: break
        }
        return request
    }
}

private func validChromeStartURL(_ raw: String) -> Bool {
    guard (1...4096).contains(raw.utf8.count),
          raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
          let components = URLComponents(string: raw),
          let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil,
          components.url != nil else { return false }
    return true
}

func finiteNumber(_ value: Any?) throws -> Double {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, abs(number.doubleValue) <= 10_000_000 else {
        throw HelperFailure.invalidArgument
    }
    return number.doubleValue
}

func integer(_ value: Any?, range: ClosedRange<Int64>) throws -> Int64 {
    // 在转换前检查范围，避免负数、浮点数、布尔值和溢出引发 Swift trap。
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
        throw HelperFailure.invalidArgument
    }
    let value = number.doubleValue
    guard value.isFinite, value.rounded(.towardZero) == value,
          value >= Double(range.lowerBound), value <= Double(range.upperBound) else {
        throw HelperFailure.invalidArgument
    }
    return Int64(value)
}

func validRequestID(_ id: String) -> Bool {
    (1...128).contains(id.unicodeScalars.count) && !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
}

final class JSONLWriter {
    private let lock = NSLock()
    private let onDisconnect: () -> Void

    init(onDisconnect: @escaping () -> Void) { self.onDisconnect = onDisconnect }

    func success(id: String, data: [String: Any]) { send(["id": id, "ok": true, "data": data]) }
    func failure(id: String, _ error: HelperFailure) {
        send(["id": id, "ok": false, "error": ["code": error.code, "message": error.message]])
    }

    private func send(_ response: [String: Any]) {
        let data: Data
        do { data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) }
        catch {
            // 不记录序列化内容；异常时也为当前请求发送一条结构化响应。
            let id = response["id"] as? String ?? ""
            data = (try? JSONSerialization.data(withJSONObject: ["id": id, "ok": false,
                "error": ["code": "INTERNAL_ERROR", "message": "原生响应编码失败"]])) ?? Data()
        }
        lock.lock()
        defer { lock.unlock() }
        let line = data + Data([10])
        line.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < line.count {
                let count = Darwin.write(STDOUT_FILENO, base.advanced(by: offset), line.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 {
                    // daemon 已离开，不能让 NSFileHandle 的 Broken pipe 异常泄露堆栈。
                    onDisconnect()
                    exit(0)
                }
                offset += count
            }
        }
    }
}
