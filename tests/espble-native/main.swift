import Foundation
import CoreGraphics

func require(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func fails(_ code: String, _ body: () throws -> Void) {
    do { try body(); require(false, "expected \(code)") }
    catch let error as HelperFailure { require(error.code == code, "expected \(code), got \(error.code)") }
    catch { require(false, "unexpected error") }
}
let bounds = WindowBounds(x: 100, y: 100, width: 1200, height: 900)
let screen = CGRect(x: 0, y: 0, width: 3440, height: 1440)
var raw: [String: Any] = ["id": "one", "action": "click", "windowId": 42, "pid": 123,
                          "expectedBounds": bounds.json, "screenX": 500, "screenY": 400, "clickCount": 1, "eb": true]
let request = try NativeRequest.decode(raw)
require(request.espBle, "native decode preserves eb")
let plan = try ESPBlePlan.make(request, screen: screen, displayCount: 1)
require(plan.arguments == ["--click", "15,28"], "map screen point to integer percent")
require(plan.point == CGPoint(x: 516, y: 403.2), "report rounded screen point")
let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
let laptopPlan = try ESPBlePlan.make(request, screen: laptop, displayCount: 1)
require(laptopPlan.arguments == ["--click", "33,41"], "map using receiving Mac's changed dimensions")
try laptopPlan.verifyScreen(laptop, displayCount: 1)
fails("BLE_UNSUPPORTED") { try laptopPlan.verifyScreen(screen, displayCount: 1) }
fails("BLE_UNSUPPORTED") { try laptopPlan.verifyScreen(laptop, displayCount: 2) }
raw["eb"] = "true"
fails("INVALID_ARGUMENT") { _ = try NativeRequest.decode(raw) }
fails("BLE_UNSUPPORTED") { _ = try ESPBlePlan.make(request, screen: screen, displayCount: 2) }
var double = request; double.clickCount = 2
fails("BLE_UNSUPPORTED") { _ = try ESPBlePlan.make(double, screen: screen, displayCount: 1) }
var outside = request; outside.point = CGPoint(x: -100, y: 200)
fails("BLE_UNSUPPORTED") { _ = try ESPBlePlan.make(outside, screen: screen, displayCount: 1) }
var narrow = request; narrow.expectedBounds = WindowBounds(x: 499, y: 399, width: 2, height: 2)
fails("BLE_UNSUPPORTED") { _ = try ESPBlePlan.make(narrow, screen: screen, displayCount: 1) }
var scroll = NativeRequest(id: "s", action: "scroll")
scroll.point = request.point; scroll.expectedBounds = bounds; scroll.deltaY = 120
require(try ESPBlePlan.make(scroll, screen: screen, displayCount: 1).arguments == ["--move", "15,28", "--scroll", "-3"], "scroll sign and documented 40px approximation")
var key = NativeRequest(id: "k", action: "press"); key.key = "Alt+ArrowLeft"
require(try ESPBlePlan.make(key, screen: screen, displayCount: 1).arguments == ["--key", "alt+left"], "reuse firmware key spelling")

var time: TimeInterval = 0
let cancellation = InputCancellation(clock: { time })
let generation = cancellation.snapshot()
let lease = try cancellation.beginExecution(generation: generation)
_ = cancellation.startCountdown(lease: lease); time = 4
let permit = try cancellation.waitForInput(generation: generation)
try cancellation.beginBLECommand(permit: permit, pointer: true) {}
require(!cancellation.pauseForUserInteraction(lease: lease, timestamp: 4, pointer: true), "BLE pointer events do not pause their own command")
require(cancellation.pauseExecution(lease: lease), "explicit pause remains active during BLE")
require(!cancellation.canConfirmInputStopped, "cannot claim an outstanding firmware command stopped")
fails("USER_PAUSED") { try cancellation.beginBLECommand(permit: permit, pointer: false) { require(false, "stale command authorized") } }
cancellation.finishBLECommand()
require(!cancellation.canConfirmInputStopped, "pause during delivery remains uncertain until recovery")
require(!cancellation.resumeExecution(lease: lease), "toolbar resume cannot clear uncertain BLE input")
print("PASS: native EB schema, coordinate/key/scroll mapping, unsupported targets, own HID events, explicit pause and uncertain delivery")

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("mcc-ble-process-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: temporary) }
func control() throws -> (InputCancellation, ChromeInputPermit) {
    var now: TimeInterval = 0
    let control = InputCancellation(clock: { now })
    let generation = control.snapshot()
    let lease = try control.beginExecution(generation: generation)
    _ = control.startCountdown(lease: lease); now = 4
    return (control, try control.beginInput(generation: generation))
}
func fixture(_ mode: String, count: Int = 2) throws -> (URL, URL) {
    let script = temporary.appendingPathComponent("client-\(UUID().uuidString)")
    let trace = script.appendingPathExtension("trace")
    let traceLiteral = String(data: try JSONSerialization.data(withJSONObject: trace.path, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
    let source = """
    #!/usr/bin/python3
    import json,sys,time
    commands = ['move 15 28', 'scroll -3'] if \(count) == 2 else ['key space'] * \(count)
    if '--dry-run' in sys.argv:
        selection = {'device': 'ESP Lab', 'deviceSelection': 'CD579B26-0054-4C51-9E71-04FA92234E60'} if '\(mode)' == 'selected' else {'device': 'pilot-2'}
        print(json.dumps(dict(selection, commands=commands))); sys.exit(0)
    if '\(mode)' == 'selected' and sys.argv[1:4] != ['--host-controlled', '--expected-device', 'CD579B26-0054-4C51-9E71-04FA92234E60']: sys.exit(4)
    for index, command in enumerate(commands):
        print('HOST_READY ' + str(index if '\(mode)' != 'bad-ready' else 99), flush=True)
        if sys.stdin.readline().strip() != 'GO ' + str(index): sys.exit(2)
        with open(\(traceLiteral), 'a') as f: f.write(str(index) + '\\n')
        if '\(mode)' == 'lost-ack': sys.exit(3)
        if '\(mode)' == 'slow': time.sleep(2)
        print('HOST_ACK ' + str(index), flush=True)
    print('HOST_DONE ' + str(len(commands)), flush=True)
    """
    try source.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return (script, trace)
}
let (client, trace) = try fixture("success")
let ble = try ESPBleInput.preflight(plan: ESPBlePlan(arguments: ["--move", "15,28", "--scroll", "-3"], point: plan.point), client: client)
let (success, successPermit) = try control()
var verified = 0
try ble.send(cancellation: success, permit: successPermit, verify: { verified += 1 })
let delivered = try String(contentsOf: trace, encoding: .utf8)
require(verified == 2 && delivered == "0\n1\n", "authorize each packet once after verifying focus")
require(success.canConfirmInputStopped, "complete ACKs clear pending delivery")
require(success.pauseForUserInteraction(lease: successPermit.lease, timestamp: 5, pointer: true), "physical pointer monitoring resumes outside BLE packet intervals")

let (selectedClient, selectedTrace) = try fixture("selected")
let (selectedControl, selectedPermit) = try control()
try ESPBleInput.preflight(plan: ble.plan, client: selectedClient).send(cancellation: selectedControl, permit: selectedPermit, verify: {})
require(try String(contentsOf: selectedTrace, encoding: .utf8) == "0\n1\n", "Host pins selected UUID from preflight through dispatch")

let (pausedClient, pausedTrace) = try fixture("success")
let (paused, pausedPermit) = try control()
var checks = 0
fails("USER_PAUSED") {
    try ESPBleInput.preflight(plan: ble.plan, client: pausedClient).send(cancellation: paused, permit: pausedPermit, verify: {
        checks += 1
        if checks == 2 { _ = paused.pauseExecution(lease: pausedPermit.lease) }
        try paused.checkInput(pausedPermit)
    })
}
require(try String(contentsOf: pausedTrace, encoding: .utf8) == "0\n", "pause between packets prevents later input")
require(paused.canConfirmInputStopped, "pause between packets has no uncertain outstanding delivery")

let (lostClient, lostTrace) = try fixture("lost-ack")
let (lost, lostPermit) = try control()
fails("BLE_CLIENT_FAILED") { try ESPBleInput.preflight(plan: ble.plan, client: lostClient).send(cancellation: lost, permit: lostPermit, verify: {}) }
require(try String(contentsOf: lostTrace, encoding: .utf8) == "0\n", "missing ACK does not retry or authorize a second packet")
require(!lost.canConfirmInputStopped && lost.transportState()["recoveryRequired"] as? Bool == true, "missing ACK requires recovery")

let (badClient, badTrace) = try fixture("bad-ready")
let (bad, badPermit) = try control()
fails("BLE_CLIENT_FAILED") { try ESPBleInput.preflight(plan: ble.plan, client: badClient).send(cancellation: bad, permit: badPermit, verify: {}) }
require(!FileManager.default.fileExists(atPath: badTrace.path), "unknown sequence receives no input permit")
let (largeClient, _) = try fixture("success", count: 17)
fails("BLE_UNSUPPORTED") { _ = try ESPBleInput.preflight(plan: ble.plan, client: largeClient) }

let (slowClient, slowTrace) = try fixture("slow")
let (inFlight, inFlightPermit) = try control()
fails("USER_PAUSED") {
    try ESPBleInput.preflight(plan: ble.plan, client: slowClient).send(cancellation: inFlight, permit: inFlightPermit, verify: {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { _ = inFlight.pauseExecution(lease: inFlightPermit.lease) }
    })
}
require(try String(contentsOf: slowTrace, encoding: .utf8) == "0\n", "in-flight pause prevents following commands")
require(!inFlight.canConfirmInputStopped, "in-flight pause does not acknowledge firmware stopped")
let sibling = temporary.appendingPathComponent("macos-ble-control")
let dummyHelper = temporary.appendingPathComponent("macos-chrome-helper")
try "not executable".write(to: sibling, atomically: true, encoding: .utf8)
require(try ESPBleInput.clientURL(executable: dummyHelper, path: "/usr/bin") == sibling, "present nonexecutable sibling does not fall back to PATH")
try FileManager.default.removeItem(at: sibling)
try FileManager.default.createSymbolicLink(at: sibling, withDestinationURL: temporary.appendingPathComponent("missing"))
require(try ESPBleInput.clientURL(executable: dummyHelper, path: "/usr/bin") == sibling, "broken sibling link does not fall back to PATH")
print("PASS: real subprocess handshake, per-packet focus checks, pause stops later packets, missing ACK locks recovery, invalid sequences and plan bound")
