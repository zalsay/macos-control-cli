import Darwin
import Foundation
import SafarierCore

struct ControlDecisionConfig: Sendable {
    let endpoint: URL, model: String, key: String
    enum Failure: Error { case invalid, disabled }
    static func load() throws -> ControlDecisionConfig {
        let dir = ProcessInfo.processInfo.environment["MCC_CONFIG_DIR"] ?? (NSHomeDirectory() + "/.config/mcc")
        guard dir.hasPrefix("/"), !dir.utf8.contains(0) else { throw Failure.invalid }
        let parts=dir.split(separator:"/",omittingEmptySubsequences:true)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." }) else { throw Failure.invalid }
        var d = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard d >= 0 else { throw Failure.invalid }
        for part in parts {
            let next=openat(d,String(part),O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(d); guard next >= 0 else { throw Failure.invalid }; d=next
        }
        defer { close(d) }
        var ds = stat(); guard fstat(d,&ds)==0, ds.st_uid==geteuid(), ds.st_mode & 0o7777 == 0o700 else { throw Failure.invalid }
        let fd = openat(d, "models.toml", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.invalid }; defer { close(fd) }
        var st=stat(), after=stat()
        guard fstat(fd,&st)==0, st.st_mode & S_IFMT == S_IFREG, st.st_uid==geteuid(), st.st_mode & 0o7777 == 0o600, st.st_nlink==1, st.st_size > 0, st.st_size <= 65536 else { throw Failure.invalid }
        let file=FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        var data=Data()
        while data.count <= 65536 {
            let chunk = try file.read(upToCount:min(8192,65537-data.count)) ?? Data()
            if chunk.isEmpty { break }; data.append(chunk)
        }
        guard data.count == st.st_size, fstat(fd,&after)==0, after.st_dev==st.st_dev, after.st_ino==st.st_ino, after.st_size==st.st_size, after.st_mode==st.st_mode, after.st_uid==st.st_uid, after.st_nlink==st.st_nlink, after.st_mtimespec.tv_sec==st.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec==st.st_mtimespec.tv_nsec, let content=String(data:data,encoding:.utf8) else { throw Failure.invalid }
        return try parse(content)
    }
    static func parse(_ content: String) throws -> ControlDecisionConfig {
        let parsed = try parseEditable(content)
        guard parsed.enabled else { throw Failure.disabled }
        return parsed.config
    }
    static func parseEditable(_ content: String) throws -> (name: String, config: ControlDecisionConfig, enabled: Bool) {
        var section = "", sections = Set<String>(), values: [String:[String:String]] = ["":[:]]
        func string(_ raw: String) throws -> String {
            if raw.hasPrefix("\"") {
                guard let parsed = try? JSONSerialization.jsonObject(with:Data(raw.utf8),options:[.fragmentsAllowed]) as? String else { throw Failure.invalid }
                return parsed
            }
            if raw.count >= 2, raw.first == "'", raw.last == "'" { let inside=String(raw.dropFirst().dropLast()); guard !inside.contains("'") else { throw Failure.invalid }; return inside }
            throw Failure.invalid
        }
        func nameOK(_ s:String) -> Bool { !s.isEmpty && s.utf8.count <= 64 && s.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 } }
        for raw in content.split(separator:"\n",omittingEmptySubsequences:false) {
            let line=raw.trimmingCharacters(in:.whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.first == "[", line.last == "]" {
                let header=String(line.dropFirst().dropLast()); guard header.hasPrefix("models.") else { throw Failure.invalid }
                section=String(header.dropFirst(7)); guard nameOK(section), sections.insert(section).inserted else { throw Failure.invalid }; values[section]=[:]; continue
            }
            guard let equal=line.firstIndex(of:"=") else { throw Failure.invalid }
            let key=line[..<equal].trimmingCharacters(in:.whitespaces), rawValue=line[line.index(after:equal)...].trimmingCharacters(in:.whitespaces)
            guard values[section]?[key] == nil else { throw Failure.invalid }
            if section.isEmpty { guard key == "default_model" else { throw Failure.invalid }; values[section]?[key] = try string(rawValue) }
            else if key == "enabled" { guard rawValue == "true" || rawValue == "false" else { throw Failure.invalid }; values[section]?[key]=rawValue }
            else { guard ["url","api_key","model"].contains(key) else { throw Failure.invalid }; values[section]?[key]=try string(rawValue) }
        }
        guard let name=values[""]?["default_model"], nameOK(name), let item=values[name], let endpoint=item["url"], let model=item["model"], let key=item["api_key"], !key.isEmpty, key.utf8.count<=1024, key.utf8.allSatisfy({(33...126).contains($0)}), !model.isEmpty, model.utf8.count<=256, model.utf8.allSatisfy({(33...126).contains($0)}), endpoint.utf8.count<=2048, endpoint.utf8.allSatisfy({(33...126).contains($0)}), let components=URLComponents(string:endpoint), components.scheme?.lowercased()=="https", components.host?.isEmpty==false, components.user==nil, components.password==nil, components.query==nil, components.fragment==nil, let url=components.url else { throw Failure.invalid }
        return (name, ControlDecisionConfig(endpoint:url,model:model,key:key), item["enabled"] != "false")
    }
}

final class ControlCancellation: @unchecked Sendable {
    private let lock=NSLock(); private var cancelled=false
    func cancel() { lock.lock(); cancelled=true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
enum ControlDecision {
    enum Failure: Error { case unavailable, cancelled }
    private final class Capture: @unchecked Sendable {
        let lock=NSLock(); var data=Data(); var overflow=false
        func add(_ chunk: Data) { lock.lock(); defer { lock.unlock() }; if data.count + chunk.count > 65540 { overflow=true } else { data.append(chunk) } }
        func value() -> (Data,Bool) { lock.lock(); defer { lock.unlock() }; return (data,overflow) }
    }
    static func decide(config: ControlDecisionConfig, request: Data, cancellation: ControlCancellation) async throws -> Data {
        try await run(config:config,request:request,cancellation:cancellation,executable:URL(fileURLWithPath:"/usr/bin/curl"))
    }
    #if SAFARIER_CONTROL_TESTING
    static func decideForTest(config: ControlDecisionConfig, request: Data, cancellation: ControlCancellation, executable: URL) async throws -> Data {
        try await run(config:config,request:request,cancellation:cancellation,executable:executable)
    }
    #endif
    private static func run(config: ControlDecisionConfig, request: Data, cancellation: ControlCancellation, executable: URL) async throws -> Data {
        try await Task.detached {
            let started = DispatchTime.now().uptimeNanoseconds
            func diagnostic(_ stage: String, value: Int? = nil) {
                let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                let detail = value.map { " value=\($0)" } ?? ""
                fputs("JEV_DIAG stage=\(stage) elapsedMs=\(elapsed)\(detail)\n", stderr)
            }
            guard !cancellation.isCancelled, request.count <= 65536, let json=String(data:request,encoding:.utf8) else { throw Failure.cancelled }
            func quote(_ s:String) -> String { s.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"").replacingOccurrences(of:"\n",with:"\\n").replacingOccurrences(of:"\r",with:"\\r") }
            let body = "url = \"\(quote(config.endpoint.absoluteString))\"\nheader = \"Authorization: Bearer \(quote(config.key))\"\nheader = \"Content-Type: application/json\"\ndata = \"\(quote(json))\"\n"
            let process=Process(), input=Pipe(), output=Pipe(), capture=Capture(), done=DispatchSemaphore(value:0)
            process.executableURL=executable
            process.arguments=["-q","--config","-","--silent","--show-error","--fail","--proto","=https","--max-time","8","--connect-timeout","3","--retry","0","--noproxy","*","--max-filesize","65536","--write-out","\n%{http_code}"]
            process.environment=["PATH":"/usr/bin:/bin", "HOME":"/var/empty"]
            process.standardInput=input; process.standardOutput=output; process.standardError=FileHandle.nullDevice
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { diagnostic("pipe_setup_failed"); throw Failure.unavailable }
            diagnostic("process_start")
            do { try process.run() } catch { diagnostic("process_start_failed"); throw error }
            DispatchQueue.global(qos:.userInitiated).async {
                defer { done.signal(); try? output.fileHandleForReading.close() }
                while let chunk = try? output.fileHandleForReading.read(upToCount:8192), !chunk.isEmpty {
                    capture.add(chunk); if capture.value().1 { break }
                }
            }
            let written=DispatchSemaphore(value:0)
            DispatchQueue.global(qos:.userInitiated).async {
                defer { written.signal(); try? input.fileHandleForWriting.close() }
                try? input.fileHandleForWriting.write(contentsOf:Data(body.utf8))
            }
            let limit=ProcessInfo.processInfo.systemUptime+8.5
            while process.isRunning {
                if cancellation.isCancelled || capture.value().1 || ProcessInfo.processInfo.systemUptime >= limit {
                    diagnostic(cancellation.isCancelled ? "cancelled" : capture.value().1 ? "overflow" : "process_timeout")
                    process.terminate(); break
                }
                Thread.sleep(forTimeInterval:0.01)
            }
            if process.isRunning {
                let terminationDeadline=ProcessInfo.processInfo.systemUptime+0.25
                while process.isRunning && ProcessInfo.processInfo.systemUptime < terminationDeadline { Thread.sleep(forTimeInterval:0.01) }
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                let killDeadline=ProcessInfo.processInfo.systemUptime+0.5
                while process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline { Thread.sleep(forTimeInterval:0.01) }
                guard !process.isRunning else { diagnostic("process_exit_timeout"); throw Failure.unavailable }
            }
            diagnostic("process_exit", value:Int(process.terminationStatus))
            guard done.wait(timeout:.now()+0.5) == .success else { diagnostic("reader_timeout"); throw Failure.unavailable }
            guard written.wait(timeout:.now()+0.5) == .success else { diagnostic("writer_timeout"); throw Failure.unavailable }
            let (captured,overflow)=capture.value()
            diagnostic("response_bytes", value:captured.count)
            if overflow { diagnostic("overflow") }
            if captured.count >= 4, captured[captured.count-4] == 10,
               let status = Int(String(decoding:captured.suffix(3), as:UTF8.self)) { diagnostic("http_status",value:status) }
            else { diagnostic("status_missing") }
            guard captured.count >= 4, captured.suffix(4) == Data("\n200".utf8) else { throw Failure.unavailable }
            let data=Data(captured.dropLast(4))
            guard !cancellation.isCancelled else { throw Failure.cancelled }
            guard !overflow, process.terminationStatus==0, !data.isEmpty else { throw Failure.unavailable }
            return data
        }.value
    }
}
