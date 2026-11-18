import Foundation
import CoreGraphics
import Darwin

struct ESPBlePlan {
    let arguments: [String]
    let point: CGPoint?

    static func make(_ request: NativeRequest, screen: CGRect, displayCount: Int) throws -> ESPBlePlan {
        func unsupported(_ message: String) -> HelperFailure { HelperFailure(code: "BLE_UNSUPPORTED", message: message) }
        switch request.action {
        case "click", "scroll":
            guard displayCount == 1, let point = request.point, screen.contains(point),
                  screen.width > 0, screen.height > 0 else {
                throw unsupported("ESP 指针当前只支持主屏单显示器，不能映射到其他屏幕")
            }
            let x = Int(((point.x - screen.minX) / screen.width * 100).rounded())
            let y = Int(((point.y - screen.minY) / screen.height * 100).rounded())
            let rounded = CGPoint(x: min(screen.maxX - 1, screen.minX + screen.width * Double(x) / 100),
                                  y: min(screen.maxY - 1, screen.minY + screen.height * Double(y) / 100))
            guard request.expectedBounds?.contains(rounded) == true else {
                throw unsupported("ESP 整数百分比取整后的坐标不在目标窗口内，未发送输入")
            }
            if request.action == "click" {
                guard request.clickCount == 1 else { throw unsupported("现有 ESP 固件不提供有时序保证的双击") }
                return ESPBlePlan(arguments: ["--click", "\(x),\(y)"], point: rounded)
            }
            // MCC scroll is in pixels; HID is in wheel notches. Keep direction and
            // document the approximation instead of silently truncating to Int8.
            let ticks = max(1, Int(ceil(Double(abs(request.deltaY)) / 40))) * (request.deltaY > 0 ? -1 : 1)
            return ESPBlePlan(arguments: ["--move", "\(x),\(y)", "--scroll", "\(ticks)"], point: rounded)
        case "type": return ESPBlePlan(arguments: ["--type", request.text], point: nil)
        case "press":
            let key = request.key.lowercased().replacingOccurrences(of: "arrow", with: "")
            return ESPBlePlan(arguments: ["--key", key], point: nil)
        default: throw unsupported("此操作不支持 ESP 输入")
        }
    }
}

// Keep the existing MBC parser, BLE connection and ACK logic in the bundled
// executable. The helper only supplies a permit for each firmware packet.
struct ESPBleInput {
    let plan: ESPBlePlan
    let client: URL
    let commands: [String]
    let expectedDevice: String?

    static func clientURL(executable: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
                          path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") throws -> URL {
        let sibling = executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("macos-ble-control")
        // A present but broken bundled client must fail; never retry via PATH.
        var metadata = stat()
        if lstat(sibling.path, &metadata) == 0 { return sibling }
        guard errno == ENOENT else {
            throw HelperFailure(code: "BLE_CLIENT_FAILED", message: "无法检查包内 BLE 客户端，不回退其他可执行文件")
        }
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = URL(fileURLWithPath: directory.isEmpty ? "." : String(directory)).appendingPathComponent("macos-ble-control")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw HelperFailure(code: "BLE_CLIENT_NOT_FOUND", message: "未找到 macos-ble-control，请使用包含 MBC 的完整构建包")
    }

    static func prepare(_ request: NativeRequest) throws -> ESPBleInput {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success else {
            throw HelperFailure(code: "BLE_UNSUPPORTED", message: "无法读取 ESP 输入的显示器范围")
        }
        let plan = try ESPBlePlan.make(request, screen: CGDisplayBounds(CGMainDisplayID()), displayCount: Int(displayCount))
        let client = try clientURL()
        return try preflight(plan: plan, client: client)
    }

    static func preflight(plan: ESPBlePlan, client: URL) throws -> ESPBleInput {
        let process = Process()
        process.executableURL = client
        process.arguments = ["--dry-run"] + plan.arguments
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let data = try collect(process, output: output, timeout: 2, check: {})
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = object["device"] as? String, !device.isEmpty,
              let commands = object["commands"] as? [String],
              !commands.isEmpty, commands.count <= 16 else {
            throw HelperFailure(code: "BLE_UNSUPPORTED", message: "ESP 输入须为受支持字符和按键，单次最多 16 个固件命令，请缩短文本")
        }
        let expectedDevice = object["deviceSelection"] as? String
        if let expectedDevice {
            guard expectedDevice == "default" ? device == "pilot-2" : UUID(uuidString: expectedDevice) != nil else {
                throw HelperFailure(code: "BLE_CLIENT_FAILED", message: "BLE 客户端设备选择回执无效")
            }
        } else if object["deviceSelection"] != nil || device != "pilot-2" {
            throw HelperFailure(code: "BLE_CLIENT_FAILED", message: "BLE 客户端设备选择回执无效")
        }
        return ESPBleInput(plan: plan, client: client, commands: commands, expectedDevice: expectedDevice)
    }

    func send(cancellation: InputCancellation, permit: ChromeInputPermit, verify: @escaping () throws -> Void) throws {
        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = client
        // Fail before any input if the saved selection changed after preflight.
        process.arguments = ["--host-controlled"] + (expectedDevice.map { ["--expected-device", $0] } ?? []) + plan.arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = input
        var completed = 0, inFlight = false, done = false
        var buffer = Data()
        defer { cancellation.abandonBLECommand() }
        _ = try Self.collect(process, output: output, timeout: 35,
                             check: { try cancellation.checkInput(permit) },
                             start: { try cancellation.inputEffect(permit: permit) { try process.run() } },
                             consume: { data in
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 10) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                if line == "HOST_READY \(completed)" && !inFlight && !done && completed < commands.count {
                    try verify()
                    let pointer = commands[completed].hasPrefix("move ") || commands[completed].hasPrefix("click ")
                    try cancellation.beginBLECommand(permit: permit, pointer: pointer) {
                        try input.fileHandleForWriting.write(contentsOf: Data("GO \(completed)\n".utf8))
                    }
                    inFlight = true
                } else if line == "HOST_ACK \(completed)" && inFlight {
                    cancellation.finishBLECommand()
                    completed += 1; inFlight = false
                } else if line == "HOST_DONE \(commands.count)" && completed == commands.count && !inFlight && !done {
                    done = true
                } else if line.hasPrefix("HOST_") {
                    throw HelperFailure(code: "BLE_CLIENT_FAILED", message: "BLE 客户端控制协议不匹配，已停止后续命令")
                }
            }
        })
        guard done && completed == commands.count && !inFlight else {
            throw HelperFailure(code: "BLE_CLIENT_FAILED", message: "未收到全部 ESP 命令的确认，不自动重试")
        }
        try cancellation.checkInput(permit)
    }

    // Read while the child runs so large dry-run plans cannot deadlock a full pipe.
    // Private MBC logs and typed text never enter the helper's JSONL stdout.
    private static func collect(_ process: Process, output: Pipe, timeout: TimeInterval,
                                check: () throws -> Void, start: (() throws -> Void)? = nil,
                                consume: ((Data) throws -> Void)? = nil) throws -> Data {
        let handle = output.fileHandleForReading
        let fd = handle.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
            throw HelperFailure(code: "BLE_CLIENT_FAILED", message: "无法创建 BLE 客户端响应管道")
        }
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            try? handle.close()
        }
        try check()
        do { if let start { try start() } else { try process.run() } }
        catch let error as HelperFailure { throw error }
        catch { throw HelperFailure(code: "BLE_CLIENT_FAILED", message: "无法启动 BLE 客户端，请检查包内可执行文件") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        repeat {
            try check()
            while true {
                let count = read(fd, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                    throw HelperFailure(code: "BLE_CLIENT_FAILED", message: "BLE 客户端响应读取失败")
                }
                if count <= 0 { break }
                let data = Data(bytes.prefix(count))
                result.append(data)
                guard result.count <= 65536 else { throw HelperFailure(code: "BLE_CLIENT_FAILED", message: "BLE 客户端响应过大") }
                try consume?(data)
            }
            if !process.isRunning { break }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw HelperFailure(code: "BLE_CLIENT_FAILED", message: "BLE 客户端超时，执行结果可能未确认，不自动重试")
            }
            Thread.sleep(forTimeInterval: 0.01)
        } while true
        // The process can exit between a nonblocking read and isRunning. Drain
        // all remaining bytes before interpreting its final ACK/DONE markers.
        while true {
            let count = read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            let data = Data(bytes.prefix(count)); result.append(data)
            guard result.count <= 65536 else { throw HelperFailure(code: "BLE_CLIENT_FAILED", message: "BLE 客户端响应过大") }
            try consume?(data)
        }
        try check()
        guard process.terminationReason == .exit && process.terminationStatus == 0 else {
            throw HelperFailure(code: "BLE_CLIENT_FAILED", message: "BLE 客户端未成功完成，检查蓝牙连接、固件和 ASCII 输入限制")
        }
        return result
    }
}
