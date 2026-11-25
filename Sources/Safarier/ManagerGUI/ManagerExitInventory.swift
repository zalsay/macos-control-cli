import Darwin
import Foundation
import SafarierCore
import SafarierControlSupport

/// Never infer ownership from process names, parent PID 1, port numbers or a socket pathname.
struct ManagerExitTarget: Hashable {
    enum Role: Hashable { case runner, daemon(String), dsh, proxy, client }
    let pid: Int32, version: UInt32, executable: String, role: Role
    var label: String {
        let name: String
        switch role {
        case .runner: name = "Runner 浏览器"
        case .daemon(let runtime): name = "SFA 服务（\(runtime.debugDescription)）"
        case .dsh: name = "本 Manager 启动的 DSH"
        case .proxy: name = "浏览器代理"
        case .client: name = "Safarier 辅助进程"
        }
        return "\(name) · PID \(pid)"
    }
    var isAlive: Bool { cs_exit_pidversion(pid) == version && ManagerExitInventory.path(pid) == executable }
    func signal(_ number: Int32) { if isAlive { _ = cs_exit_signal(pid, version, number) } }
}

enum ManagerExitInventory {
    private static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }; return String(cString: resolved)
    }
    static func path(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }
    /// KERN_PROCARGS2 returns argc, executable, padding, argv and environment. Never extract or log the environment.
    static func arguments(_ pid: Int32) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 4_194_304 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc > 0, argc < 16384, let zero = bytes[4..<size].firstIndex(of: 0) else { return nil }
        var i = zero, argv = [String]()
        while i < size && bytes[i] == 0 { i += 1 }
        for _ in 0..<argc {
            guard i < size, let end = bytes[i..<size].firstIndex(of: 0), let arg = String(bytes: bytes[i..<end], encoding: .utf8) else { return nil }
            argv.append(arg); i = end + 1
        }
        return Array(argv.dropFirst())
    }

    static func snapshot(bundle: Bundle = .main, dshPID: Int32?) throws -> [ManagerExitTarget] {
        guard let root = canonical(bundle.bundlePath), let executable = bundle.executablePath, let main = canonical(executable) else { throw ManagerHostFailure.unavailable("无法确定当前 App 的安装路径。") }
        let helpers = root + "/Contents/Helpers/", runner = helpers + "Safarier AI Browser.app/Contents/"
        let proxyPaths = [helpers,runner + "Helpers/"].flatMap { [$0 + "mihomo", $0 + "sing-box"] }
        var capacity = max(Int(proc_listallpids(nil, 0)) + 64, 256)
        var pids: [Int32] = []
        while true {
            guard capacity <= 1_000_000 else { throw ManagerHostFailure.unavailable("无法完整枚举退出目标。") }
            pids = [Int32](repeating: 0, count: capacity)
            let count = Int(proc_listallpids(&pids, Int32(capacity * 4)))
            guard count > 0 else { throw ManagerHostFailure.unavailable("无法枚举退出目标。") }
            if count < capacity { pids.removeLast(capacity-count); break }; capacity *= 2
        }
        var targets: [ManagerExitTarget] = []
        for pid in pids where pid > 1 && pid != getpid() {
            guard let exe = path(pid) else { continue }
            guard pid == dshPID || exe == main || proxyPaths.contains(exe) || exe == runner + "MacOS/Safarier AI Browser" || exe == runner + "MacOS/Safarier" else { continue }
            let initialVersion = cs_exit_pidversion(pid)
            let role: ManagerExitTarget.Role
            if pid == dshPID { role = .dsh }
            else if exe == runner + "MacOS/Safarier AI Browser" || exe == runner + "MacOS/Safarier" { role = .runner }
            else if proxyPaths.contains(exe) { role = .proxy }
            else if exe == main {
                guard let args = arguments(pid) else { if path(pid) == nil { continue }; throw ManagerHostFailure.unavailable("无法核验 Safarier 进程 PID \(pid) 的角色。") }
                if args.first == "control", let cmd = try? ControlCLIParser.parse(args), cmd.operation == .daemonServe {
                    guard cmd.options.applicationPath == nil || cmd.options.applicationPath.flatMap(canonical) == root else { continue }
                    role = .daemon(cmd.options.runtimePath ?? NSHomeDirectory() + "/.safarier-control")
                } else { role = .client }
            } else { continue }
            var info = proc_bsdinfo(); let len = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, len) == len, info.pbi_uid == geteuid(), info.pbi_status != 5 else { continue }
            let version = cs_exit_pidversion(pid)
            guard version != 0, version == initialVersion, path(pid) == exe else {
                if path(pid) == nil { continue }; throw ManagerHostFailure.unavailable("无法核验 PID \(pid) 的进程身份；没有按名称结束进程。")
            }
            targets.append(.init(pid: pid, version: version, executable: exe, role: role))
        }
        return targets.sorted { $0.pid < $1.pid }
    }
    static func wait(_ targets: [ManagerExitTarget]) async -> [ManagerExitTarget] {
        for _ in 0..<25 {
            if !targets.contains(where: \.isAlive) { return [] }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return targets.filter(\.isAlive)
    }
}
