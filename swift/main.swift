import Foundation
import AppKit
import Darwin

// 管道响应不经过 stdio 缓冲；AppKit 主线程始终留给 RunLoop。
setbuf(stdout, nil)
signal(SIGPIPE, SIG_IGN)
let cancellation = InputCancellation()
let writer = JSONLWriter(onDisconnect: { cancellation.cancel() })
if CommandLine.arguments.count != 1 {
    writer.failure(id: "", HelperFailure(code: "INVALID_ARGUMENT", message: "原生 helper 仅接受 stdin JSONL，不接受命令行参数"))
    exit(1)
}
_ = NSApplication.shared.setActivationPolicy(.accessory)
let desktop = ChromeDesktop()
let capture = ChromeCapture(desktop: desktop, cancellation: cancellation)
let input = ChromeInput(desktop: desktop, cancellation: cancellation)
let fileSelector = ChromeFileSelector(desktop: desktop, cancellation: cancellation)
let actionQueue = DispatchQueue(label: "com.copis.chrome-cli.native-actions", qos: .userInitiated)
let maxLineBytes = 65_536

func handleLine(_ line: Data, oversized: Bool) {
    if oversized {
        writer.failure(id: "", HelperFailure(code: "REQUEST_TOO_LARGE", message: "单行请求超过原生协议大小限制"))
        return
    }
    var responseID = ""
    do {
        guard let json = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw HelperFailure(code: "INVALID_REQUEST", message: "每行必须是有效的 JSON 请求对象")
        }
        if let id = json["id"] as? String, validRequestID(id) { responseID = id }
        var decodedRequest = try NativeRequest.decode(json)
        if ["click", "scroll", "type", "press", "select-file"].contains(decodedRequest.action) {
            decodedRequest.inputEpoch = cancellation.inputSnapshot()
        }
        let request = decodedRequest
        if request.action == "cancel" {
            // 直接在 stdin 线程处理，不排在截图、焦点等待或文本输入后面。
            cancellation.cancel()
            writer.success(id: request.id, data: ["cancelled": true])
            return
        }
        let generation = cancellation.snapshot()
        actionQueue.async {
            autoreleasepool {
                do {
                    let result: [String: Any]
                    switch request.action {
                    case "permissions": result = desktop.permissions(request: request.requestPermissions)
                    case "windows": result = ["windows": desktop.windows().map(\.json)]
                    case "window":
                        guard let target = request.target else { throw HelperFailure.invalidArgument }
                        result = ["window": try desktop.window(target).json]
                    case "observe":
                        guard let target = request.target else { throw HelperFailure.invalidArgument }
                        result = try capture.observe(target, imagePath: request.imagePath, generation: generation)
                    case "select-file": result = try fileSelector.select(request, generation: generation)
                    case "click", "scroll", "type", "press": result = try input.send(request, generation: generation)
                    default: throw HelperFailure(code: "UNKNOWN_ACTION", message: "不支持该原生动作")
                    }
                    writer.success(id: request.id, data: result)
                } catch let error as HelperFailure {
                    writer.failure(id: request.id, error)
                } catch {
                    // 不输出系统错误详情，避免路径、窗口标题或输入内容出现在日志中。
                    writer.failure(id: request.id, HelperFailure(code: "INTERNAL_ERROR", message: "原生动作未能完成"))
                }
            }
        }
    } catch let error as HelperFailure {
        writer.failure(id: responseID, error)
    } catch {
        writer.failure(id: responseID, HelperFailure(code: "INVALID_REQUEST", message: "每行必须是有效的 JSON 请求对象"))
    }
}

DispatchQueue.global(qos: .userInitiated).async {
    var line = Data()
    var oversized = false
    var bytes = [UInt8](repeating: 0, count: 8192)
    while true {
        let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { break }
        for byte in bytes.prefix(count) {
            if byte == 10 {
                autoreleasepool { handleLine(line, oversized: oversized) }
                line.removeAll(keepingCapacity: true)
                oversized = false
            } else if !oversized {
                if line.count == maxLineBytes {
                    oversized = true
                    line.removeAll(keepingCapacity: true)
                } else { line.append(byte) }
            }
        }
    }
    if !line.isEmpty || oversized { autoreleasepool { handleLine(line, oversized: oversized) } }
    // EOF 取消仍在执行/排队的桌面副作用，读操作完成后退出；每条已读请求仍有响应。
    cancellation.cancel()
    actionQueue.async { exit(0) }
}
// 交互式 NSPanel 需要 AppKit 完成启动并派发鼠标事件；普通 RunLoop 不能替代应用事件循环。
NSApplication.shared.run()
