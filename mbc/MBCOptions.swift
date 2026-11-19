import Foundation

// Use macOS desktop coordinates (the same dimensions used for percent mapping),
// not Retina backing pixels. HID report coordinates remain normalized.
struct ScreenSync {
    let command: String
    var reply: String { "OK " + command }

    init?(bounds: CGRect) {
        guard let width = Int(exactly: bounds.size.width), let height = Int(exactly: bounds.size.height),
              (2...65535).contains(width), (2...65535).contains(height) else { return nil }
        command = "screen \(width) \(height)"
    }
}

enum MBCError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self { case .invalid(let message): return message }
    }
}

enum BLEAction {
    case command(String)
    case clickCurrent

    var preview: String {
        switch self {
        case .command(let command): return command
        case .clickCurrent: return "click <current-position>"
        }
    }
}

struct MBCOptions {
    var help = false
    var dryRun = false
    var actions: [BLEAction] = []

    static let usage = """
    mbc / macos-ble-control — 通过 BLE 控制 ESP32-S3 pilot-2 的鼠标和键盘

    用法：mbc [操作 ...] [--dry-run]
      --help, -h          显示帮助；不连接蓝牙
      --move x,y          曲线移动到屏幕百分比坐标；x/y 为 0–100 整数
      --click [x,y]       移动并左键单击；省略坐标使用前一移动目标或当前位置
      --type "text"       输入美式键盘 ASCII；支持换行、Tab、空格及长文本分段
      --key key           单键或组合键，例如 enter、cmd+a、alt+left、cmd+shift+z
      --scroll v[,h]      滚轮，-127–127；正数向上/右，负数向下/左
      --status            查询 ESP 连接状态
      --dry-run           仅输出 JSON 命令计划；不连接蓝牙、不发送操作

    示例：
      mbc --move 52,54
      mbc --move 52,54 --click
      mbc --click 52,54
      mbc --type 'Hello 123!' --key enter
      macos-ble-control --discover-json
      macos-ble-control --probe-json <UUID>
      macos-ble-control --device <UUID> --status
      macos-ble-control --status

    操作按参数顺序执行，逐条等待固件回执。每次连接/每条命令超时 20 秒；
    失败即停止，不自动重试。OK 表示固件已处理命令，需另行确认界面结果。
    目标设备固定为 pilot-2，需先与目标 Mac 配对；输入发送到目标 Mac 当前焦点。
    坐标是主屏百分比，不是像素；移动前同步当前主屏尺寸，需新版 pilot-2 固件。
    --click 无前一坐标时读取本机主屏指针并取整到百分比，会产生取整偏移；
    这要求控制端与 HID 接收端是同一台 Mac。跨设备控制请显式传入坐标。
    --type 不支持直接输入中文/任意 Unicode，实际字符取决于目标 Mac 的输入源。
    """ + "\n"

    static func integer(_ value: String, range: ClosedRange<Int>) throws -> Int {
        let digits = value.hasPrefix("-") ? value.dropFirst() : value[...]
        guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let number = Int(value), range.contains(number) else {
            throw MBCError.invalid("数值必须是 \(range.lowerBound)…\(range.upperBound) 范围内的整数：\(value)")
        }
        return number
    }

    static func coordinate(_ value: String) throws -> String {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw MBCError.invalid("坐标格式应为 x,y，例如 52,54") }
        return "\(try integer(String(parts[0]), range: 0...100)) \(try integer(String(parts[1]), range: 0...100))"
    }

    static func validateKey(_ input: String) throws -> String {
        var key = input.lowercased()
        while let prefix = ["ctrl+", "shift+", "alt+", "gui+", "cmd+"].first(where: { key.hasPrefix($0) }) {
            key.removeFirst(prefix.count)
        }
        let names: Set<String> = ["enter", "return", "esc", "escape", "backspace", "bs", "tab", "space",
                                  "delete", "del", "right", "left", "down", "up", "home", "end", "pageup", "pagedown",
                                  "capslock", "printscreen", "scrolllock", "pause", "insert"]
        let single = key.utf8.count == 1 && key.utf8.first.map { $0 >= 33 && $0 <= 126 } == true
        let function = key.hasPrefix("f") && (try? integer(String(key.dropFirst()), range: 1...24)) != nil
        guard names.contains(key) || single || function else { throw MBCError.invalid("不支持的按键：\(input)") }
        // Lowercase modifiers/names, preserving a single uppercase character's Shift mapping.
        if single, let last = input.last { return String(input.dropLast()).lowercased() + String(last) }
        return input.lowercased()
    }

    static func textActions(_ text: String) throws -> [BLEAction] {
        guard !text.isEmpty, text.utf8.allSatisfy({ (32...126).contains($0) || $0 == 10 || $0 == 9 }) else {
            throw MBCError.invalid("--type 需要非空 ASCII 文本；仅额外支持换行和 Tab。中文/其他控制字符暂不支持")
        }
        var actions: [BLEAction] = []
        var buffer = ""
        func flush() {
            // Firmware trims the whole command, so trailing spaces must use key events.
            let spaces = buffer.reversed().prefix(while: { $0 == " " }).count
            let content = String(buffer.dropLast(spaces))
            if !content.isEmpty { actions.append(.command("type " + content)) }
            for _ in 0..<spaces { actions.append(.command("key space")) }
            buffer = ""
        }
        for character in text {
            if character == "\n" || character == "\t" {
                flush()
                actions.append(.command(character == "\n" ? "key enter" : "key tab"))
            } else {
                buffer.append(character)
                // 5-byte prefix + 14 ASCII bytes + newline fits even a 20-byte ATT payload.
                if buffer.utf8.count == 14 { flush() }
            }
        }
        flush()
        return actions
    }

    static func parse(_ args: [String], legacy: Bool = false) throws -> MBCOptions {
        var result = MBCOptions()
        if args.isEmpty {
            result.help = true
            return result
        }
        if legacy && !args[0].hasPrefix("--") {
            for command in args {
                guard !command.contains("\n"), !command.contains("\r"), command.utf8.count <= 127 else {
                    throw MBCError.invalid("旧式单条命令必须不含换行，且最多 127 字节")
                }
            }
            result.actions = args.map(BLEAction.command)
            return result
        }
        var index = 0
        var previousPosition: String?
        func value(_ flag: String) throws -> String {
            guard index < args.count else { throw MBCError.invalid("\(flag) 缺少参数") }
            let value = args[index]
            index += 1
            return value
        }
        while index < args.count {
            let flag = args[index]
            index += 1
            switch flag {
            case "--help", "-h": result.help = true; return result
            case "--dry-run": result.dryRun = true
            case "--move":
                let point = try coordinate(value(flag))
                result.actions.append(.command("move " + point))
                previousPosition = point
            case "--click":
                if index < args.count && !args[index].hasPrefix("--") {
                    let point = try coordinate(value(flag))
                    result.actions.append(.command("click " + point))
                    previousPosition = point
                } else if let point = previousPosition {
                    result.actions.append(.command("click " + point))
                } else {
                    result.actions.append(.clickCurrent)
                }
            case "--type": result.actions += try textActions(value(flag))
            case "--key": result.actions.append(.command("key " + (try validateKey(value(flag)))))
            case "--scroll":
                let parts = try value(flag).split(separator: ",", omittingEmptySubsequences: false)
                guard (1...2).contains(parts.count) else { throw MBCError.invalid("滚轮格式应为 v 或 v,h") }
                let vertical = try integer(String(parts[0]), range: -127...127)
                let horizontal = parts.count == 2 ? try integer(String(parts[1]), range: -127...127) : 0
                result.actions.append(.command("scroll \(vertical) \(horizontal)"))
            case "--status": result.actions.append(.command("status"))
            default: throw MBCError.invalid("未知参数：\(flag)；请运行 mbc --help")
            }
        }
        guard !result.actions.isEmpty else { throw MBCError.invalid("请指定操作；运行 mbc --help 查看帮助") }
        return result
    }
}
