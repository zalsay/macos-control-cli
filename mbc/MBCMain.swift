import Foundation
import CoreBluetooth
import CoreGraphics
import Darwin

let serviceID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
let rxID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
let txID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

final class Client: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
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
    var deadline = Date(timeIntervalSinceNow: 20)
    let hostControlled: Bool
    var commandNumber = 0

    init(actions: [BLEAction], hostControlled: Bool = false) {
        self.actions = actions
        self.hostControlled = hostControlled
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }
    func fail(_ message: String) {
        print("ERROR: \(message)")
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
        if let p = devices.first(where: { $0.name == "pilot-2" }) {
            connect(p)
        } else {
            manager.scanForPeripherals(withServices: nil)
        }
    }
    func centralManager(_ manager: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        if name == "pilot-2" { connect(p) }
    }
    func centralManager(_ manager: CBCentralManager, didConnect p: CBPeripheral) {
        print("Connected to \(p.name ?? "pilot-2") via BLE")
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
        let command: String
        switch actions.removeFirst() {
        case .command(let value): command = value
        case .clickCurrent:
            let screen = CGDisplayBounds(CGMainDisplayID())
            guard let point = CGEvent(source: nil)?.location, screen.contains(point) else {
                fail("Cannot read pointer on main screen; use --click x,y"); return
            }
            let x = Int(((point.x - screen.minX) / screen.width * 100).rounded())
            let y = Int(((point.y - screen.minY) / screen.height * 100).rounded())
            command = "click \(x) \(y)"
        }
        let verb = command.split(separator: " ").first.map(String.init) ?? ""
        switch verb {
        case "move", "click", "press", "scroll": expectedReply = "OK " + command
        case "type": expectedReply = "OK type \""
        case "key": expectedReply = "OK key"
        case "status": expectedReply = "OK connected="
        default: expectedReply = "OK"
        }
        deadline = Date(timeIntervalSinceNow: 20)
        let write = { [self] in
            guard !done else { return }
            print("SEND: \(command)")
            waiting = true
            writeConfirmed = false
            replyConfirmed = false
            deadline = Date(timeIntervalSinceNow: 20)
            p.writeValue(Data((command + "\n").utf8), for: rx, type: .withResponse)
        }
        if hostControlled {
            let number = commandNumber
            print("HOST_READY \(number)")
            DispatchQueue.global().async { [self] in
                let authorization = readLine()
                DispatchQueue.main.async { [self] in
                    guard !done else { return }
                    guard authorization == "GO \(number)" else { fail("Host input permit missing"); return }
                    write()
                }
            }
        } else { write() }
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
        if hostControlled { print("HOST_ACK \(commandNumber)"); commandNumber += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.sendNext() }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let error { fail(error.localizedDescription); return }
        guard c.uuid == txID, let data = c.value, let message = String(data: data, encoding: .utf8) else { return }
        print("RECV: \(message)")
        if message.hasPrefix("ERR") { fail(message); return }
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
            let options = try MBCOptions.parse(args, legacy: legacy)
            if options.help { print(MBCOptions.usage, terminator: ""); return }
            if options.dryRun {
                let data = try JSONSerialization.data(withJSONObject: ["device": "pilot-2", "commands": options.actions.map(\.preview)], options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                return
            }
            let client = Client(actions: options.actions, hostControlled: hostControlled)
            while !client.done && Date() < client.deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            if !client.done { client.fail("Timed out after 20 seconds; execution uncertain, not retried") }
            client.close()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            exit(client.failed ? 1 : 0)
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(2)
        }
    }
}
