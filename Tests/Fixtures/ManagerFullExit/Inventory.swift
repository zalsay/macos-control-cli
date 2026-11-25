import Foundation
import Darwin

enum ManagerHostFailure: Error { case unavailable(String) }
@main struct InventorySmoke {
    static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let bundle = Bundle(url: dir)!, exe = bundle.executableURL!
        var children: [Process] = []
        defer { for child in children where child.isRunning { child.terminate(); child.waitUntilExit() } }
        func launch(_ binary: URL, _ args: [String] = []) throws -> Int32 {
            let p = Process(); p.executableURL = binary; p.arguments = args; try p.run(); children.append(p); return p.processIdentifier
        }
        let separate = dir.deletingLastPathComponent().appendingPathComponent("unrelated")
        let daemon = try launch(exe, ["control","daemon","serve","--app",dir.path,"--runtime","/tmp/fixture with spaces"])
        let runner = try launch(dir.appendingPathComponent("Contents/Helpers/Safarier AI Browser.app/Contents/MacOS/Safarier AI Browser"))
        let dsh = try launch(separate), unrelated = try launch(separate)
        _ = try launch(exe, ["control","daemon","serve","--app","/tmp/another.app","--runtime","/tmp/other"])
        let inventory = try ManagerExitInventory.snapshot(bundle: bundle, dshPID: dsh)
        precondition(Set(inventory.map(\.pid)) == Set([runner, dsh, daemon]), "scope mismatch: \(inventory.map(\.label))")
        precondition(inventory.first { $0.pid == daemon }?.role == .daemon("/tmp/fixture with spaces"))
        for item in inventory { item.signal(SIGTERM) }; let left = await ManagerExitInventory.wait(inventory)
        precondition(left.isEmpty && kill(unrelated,0) == 0)
        print("PASS: exact bundle/role, independent SFA runtime, owned DSH, unrelated processes untouched")
    }
}
