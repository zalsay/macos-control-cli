import Foundation
import CoreBluetooth
import CoreGraphics
import Darwin

let serviceID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
let rxID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
let txID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

private struct DeviceChoice: Codable {
    let id: UUID
    let name: String

    static func saved() throws -> DeviceChoice? {
        let env = ProcessInfo.processInfo.environment
        let path = env["MCC_CONFIG_DIR"] ?? (NSHomeDirectory() + "/.config/mcc")
        guard path.hasPrefix("/") else { throw MBCError.invalid("MCC_CONFIG_DIR 必须为绝对路径") }
        let descriptor = open(path + "/ble-device.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw MBCError.invalid("无法读取 BLE 设备配置")
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), (info.st_mode & 0o077) == 0, info.st_size <= 4096,
              let data = try file.read(upToCount: 4097), data.count <= 4096 else {
            throw MBCError.invalid("BLE 设备配置必须为当前用户的私有普通文件")
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

private final class Client: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var rx: CBCharacteristic?
    var tx: CBCharacteristic?
    var actions: [BLEAction]
    var done = false
    var failed = false
    var waiting = false
    var writeConfirmed = false
    var replyConfirmed = false
    var expectedReply = ""
    private var screenConfirmed: (() -> Void)?
    var deadline = Date(timeIntervalSinceNow: 20)
    let hostControlled: Bool
    var commandNumber = 0
    let device: DeviceChoice?
    let discovering: Bool
    var discovered: [UUID: DeviceChoice] = [:]
    var scanStarted = false

    init(actions: [BLEAction], hostControlled: Bool = false, device: DeviceChoice? = nil, discovering: Bool = false) {
        self.actions = actions
        self.hostControlled = hostControlled
        self.device = device
        self.discovering = discovering
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }
    func fail(_ message: String) {
        print("ERROR: \(message)")
        screenConfirmed = nil
        failed = true
        done = true
    }
    func close() {
        central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }
    func connect(_ p: CBPeripheral) {
        guard peripheral == nil else { return }
        peripheral = p
        p.delegate = self
        central.stopScan()
        central.connect(p)
    }
    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        guard manager.state == .poweredOn else {
            if manager.state != .unknown && manager.state != .resetting {
                fail("Bluetooth state \(manager.state.rawValue)")
            }
            return
        }
        let devices = manager.retrieveConnectedPeripherals(withServices: [serviceID, CBUUID(string: "1812")])
        guard !scanStarted else { return }
        scanStarted = true
        if discovering {
            for p in devices where p.name == "pilot-2" {
                discovered[p.identifier] = DeviceChoice(id: p.identifier, name: "pilot-2")
            }
            for p in manager.retrieveConnectedPeripherals(withServices: [serviceID]) {
                discovered[p.identifier] = DeviceChoice(id: p.identifier, name: p.name ?? "ESP32")
            }
            // Existing pilot-2 firmware advertises HID, not its command service.
            manager.scanForPeripherals(withServices: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.done = true }
        } else if let p = devices.first(where: { matches($0.identifier, $0.name) }) {
            connect(p)
        } else if let device, let p = manager.retrievePeripherals(withIdentifiers: [device.id]).first {
            connect(p)
        } else {
            manager.scanForPeripherals(withServices: nil)
        }
    }
    func centralManager(_ manager: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        if discovering {
            let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            guard name == "pilot-2" || advertised.contains(serviceID) else { return }
            if discovered.count < 128 || discovered[p.identifier] != nil {
                discovered[p.identifier] = DeviceChoice(id: p.identifier, name: name ?? "ESP32")
            }
        } else if matches(p.identifier, name) { connect(p) }
    }
    private func matches(_ id: UUID, _ name: String?) -> Bool {
        if let device { return device.id == id }
        return name == "pilot-2"
    }
    func centralManager(_ manager: CBCentralManager, didConnect p: CBPeripheral) {
        print("Connected to \(p.name ?? device?.name ?? "pilot-2") via BLE")
        p.discoverServices([serviceID])
    }
    func centralManager(_ manager: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        fail(error?.localizedDescription ?? "Connection failed")
    }
    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if !done { fail(error?.localizedDescription ?? "Disconnected") }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { fail(error.localizedDescription); return }
        guard let service = p.services?.first(where: { $0.uuid == serviceID }) else {
            fail("NUS command service missing"); return
        }
        p.discoverCharacteristics([rxID, txID], for: service)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { fail(error.localizedDescription); return }
        rx = service.characteristics?.first(where: { $0.uuid == rxID })
        tx = service.characteristics?.first(where: { $0.uuid == txID })
        guard rx != nil, let tx else { fail("NUS characteristics missing"); return }
        guard rx!.properties.contains(.write), tx.properties.contains(.notify) else {
            fail("NUS requires write-with-response and notify characteristics"); return
        }
        // Validate the entire sequence before the first input reaches the device.
        let limit = min(128, p.maximumWriteValueLength(for: .withResponse))
        for action in actions {
            if case .command(let command) = action, command.utf8.count + 1 > limit {
                fail("Command exceeds BLE/firmware packet limit of \(limit) bytes"); return
            }
        }
        p.setNotifyValue(true, for: tx)
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let error { fail(error.localizedDescription); return }
        guard c.isNotifying else { fail("Notifications unavailable"); return }
        sendNext()
    }
    func sendNext() {
        guard !done, let p = peripheral, let rx else { return }
        if actions.isEmpty {
            if hostControlled { print("HOST_DONE \(commandNumber)") }
            done = true; return
        }
        let display = CGMainDisplayID()
        let screen = CGDisplayBounds(display)
        let command: String
        switch actions.removeFirst() {
        case .command(let value): command = value
        case .clickCurrent:
            guard let point = CGEvent(source: nil)?.location, screen.contains(point) else {
                fail("Cannot read pointer on main screen; use --click x,y"); return
            }
            let x = Int(((point.x - screen.minX) / screen.width * 100).rounded())
            let y = Int(((point.y - screen.minY) / screen.height * 100).rounded())
            command = "click \(x) \(y)"
        }
        let verb = command.split(separator: " ").first.map(String.init) ?? ""
        let reply: String
        switch verb {
        case "move", "click", "press", "scroll": reply = "OK " + command
        case "type": reply = "OK type \""
        case "key": reply = "OK key"
        case "status": reply = "OK connected="
        default: reply = "OK"
        }
        let pointer = ["move", "click", "press"].contains(verb)
        let authorized = { [self] in
            authorizeAndWrite(command, reply: reply, peripheral: p, rx: rx,
                              validate: { !pointer || (CGMainDisplayID() == display && CGDisplayBounds(display) == screen) })
        }
        if pointer {
            guard let size = ScreenSync(bounds: screen) else { fail("Cannot read a valid main screen size"); return }
            let sync = size.command
            guard sync.utf8.count + 1 <= min(128, p.maximumWriteValueLength(for: .withResponse)) else {
                fail("Screen size command exceeds BLE packet limit"); return
            }
            // A screen update never moves the pointer. Wait for both confirmations
            // before asking the Host to authorize the actual input packet.
            screenConfirmed = authorized
            write(sync, reply: size.reply, peripheral: p, rx: rx)
        } else {
            authorized()
        }
    }
    private func write(_ command: String, reply: String, peripheral: CBPeripheral, rx: CBCharacteristic) {
        expectedReply = reply
        print("SEND: \(command)")
        waiting = true
        writeConfirmed = false
        replyConfirmed = false
        deadline = Date(timeIntervalSinceNow: 20)
        peripheral.writeValue(Data((command + "\n").utf8), for: rx, type: .withResponse)
    }
    private func authorizeAndWrite(_ command: String, reply: String, peripheral: CBPeripheral,
                                   rx: CBCharacteristic, validate: @escaping () -> Bool) {
        let send = { [self] in
            guard !done else { return }
            guard validate() else { fail("Main display changed; pointer command not sent"); return }
            write(command, reply: reply, peripheral: peripheral, rx: rx)
        }
        if hostControlled {
            let number = commandNumber
            print("HOST_READY \(number)")
            DispatchQueue.global().async { [self] in
                let authorization = readLine()
                DispatchQueue.main.async { [self] in
                    guard !done else { return }
                    guard authorization == "GO \(number)" else { fail("Host input permit missing"); return }
                    send()
                }
            }
        } else { send() }
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error { fail(error.localizedDescription); return }
        guard c.uuid == rxID, waiting else { return }
        writeConfirmed = true
        advanceIfConfirmed()
    }
    func advanceIfConfirmed() {
        guard !done, waiting, writeConfirmed, replyConfirmed else { return }
        waiting = false
        if let confirmed = screenConfirmed {
            screenConfirmed = nil
            confirmed()
            return
        }
        if hostControlled { print("HOST_ACK \(commandNumber)"); commandNumber += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.sendNext() }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let error { fail(error.localizedDescription); return }
        guard c.uuid == txID, let data = c.value, let message = String(data: data, encoding: .utf8) else { return }
        print("RECV: \(message)")
        if message.hasPrefix("ERR") {
            fail(screenConfirmed == nil ? message : "ESP rejected screen synchronization; use updated pilot-2 firmware (\(message))")
            return
        }
        if waiting && message.hasPrefix("OK") {
            let matches = expectedReply.hasSuffix("=") || expectedReply.hasSuffix("\"") || expectedReply == "OK"
                ? message.hasPrefix(expectedReply) : message == expectedReply
            guard matches else { fail("Unexpected firmware reply; sequence stopped"); return }
            replyConfirmed = true
            if message.hasPrefix("OK move ") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let point = CGEvent(source: nil)?.location {
                        print("CURSOR: \(point.x) \(point.y)")
                    }
                }
            }
            advanceIfConfirmed()
        }
    }
}

@main
enum MBCMain {
    static func main() {
        do {
            setbuf(stdout, nil)
            let legacy = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "ble-command-probe"
            var args = Array(CommandLine.arguments.dropFirst())
            let hostControlled = args.first == "--host-controlled"
            if hostControlled { args.removeFirst() }
            var expectedDevice: String?
            if hostControlled && args.first == "--expected-device" {
                guard args.count >= 2 else { throw MBCError.invalid("缺少预检的设备标识") }
                expectedDevice = args[1]
                args.removeFirst(2)
            }
            let discovery = !hostControlled && args == ["--discover-json"]
            let probe = !hostControlled && args.first == "--probe-json"
            var explicit: DeviceChoice?
            // Use a leading option to keep arguments consumed by --type intact.
            if !hostControlled, args.first == "--device" || probe {
                guard args.count >= 2, let id = UUID(uuidString: args[1]), !probe || args.count == 2 else {
                    throw MBCError.invalid("需要有效的蓝牙设备 UUID")
                }
                explicit = DeviceChoice(id: id, name: "ESP32")
                args.removeFirst(2)
            }
            let options = try MBCOptions.parse(probe ? ["--status"] : discovery ? ["--help"] : args, legacy: legacy)
            if !discovery && options.help { print(MBCOptions.usage, terminator: ""); return }
            let device = discovery ? nil : try explicit ?? DeviceChoice.saved()
            let selection = device?.id.uuidString ?? "default"
            if let expectedDevice, selection.caseInsensitiveCompare(expectedDevice) != .orderedSame {
                throw MBCError.invalid("BLE 设备在预检后已变更，未发送输入")
            }
            if options.dryRun {
                var preview: [String: Any] = ["device": device?.name ?? "pilot-2", "deviceSelection": selection, "commands": options.actions.map(\.preview)]
                if let device { preview["deviceId"] = device.id.uuidString }
                let data = try JSONSerialization.data(withJSONObject: preview, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                return
            }
            let client = Client(actions: options.actions, hostControlled: hostControlled, device: device, discovering: discovery)
            while !client.done && Date() < client.deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            if !client.done { client.fail("Timed out after 20 seconds; execution uncertain, not retried") }
            client.close()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            if !client.failed && discovery {
                let devices = client.discovered.values.sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
                print(String(decoding: try JSONEncoder().encode(devices), as: UTF8.self))
            } else if !client.failed && probe, let p = client.peripheral {
                let selected = DeviceChoice(id: p.identifier, name: p.name ?? "ESP32")
                print(String(decoding: try JSONEncoder().encode(selected), as: UTF8.self))
            }
            exit(client.failed ? 1 : 0)
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(2)
        }
    }
}
