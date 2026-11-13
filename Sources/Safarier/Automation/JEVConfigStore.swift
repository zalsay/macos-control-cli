import Darwin
import Foundation

/// The same constrained TOML parser is used by the controller and editor.
/// config.lock coordinates with MCC; a non-cooperating same-UID writer can
/// still race the final filesystem rename between the last check and commit.
struct JEVConfigStore {
    enum Failure: Error { case unsafe, unsupported, changed, busy, invalid, committedUnconfirmed }
    struct Snapshot: CustomStringConvertible {
        fileprivate let content: String?
        fileprivate let name: String
        fileprivate let existingKey: String?
        let enabled: Bool, endpoint: String, model: String
        var hasKey: Bool { existingKey != nil }
        var description: String { "JEVConfigSnapshot(redacted)" }
    }
    let directory: String
    static var defaultDirectory: String { ProcessInfo.processInfo.environment["MCC_CONFIG_DIR"] ?? (NSHomeDirectory() + "/.config/mcc") }
    var path: String { directory + "/models.toml" }
    private func directoryFD(create: Bool) throws -> Int32? {
        guard directory.hasPrefix("/"), !directory.utf8.contains(0) else { throw Failure.unsafe }
        let parts=directory.split(separator:"/",omittingEmptySubsequences:true)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." }) else { throw Failure.unsafe }
        var fd=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unsafe }
        for part in parts {
            var next=openat(fd,String(part),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            if next < 0 && errno == ENOENT && create {
                guard mkdirat(fd,String(part),0o700) == 0 || errno == EEXIST else { close(fd); throw Failure.unsafe }
                next=openat(fd,String(part),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            }
            if next < 0 {
                let absent = errno == ENOENT; close(fd)
                if absent && !create { return nil }; throw Failure.unsafe
            }
            close(fd);fd=next
        }
        var st=stat()
        guard fstat(fd,&st)==0, st.st_uid==geteuid(), st.st_mode & 0o7777 == 0o700 else { close(fd);throw Failure.unsafe }
        return fd
    }
    private func readFile(_ dir: Int32) throws -> String? {
        let fd=openat(dir,"models.toml",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        if fd < 0 { if errno==ENOENT { return nil }; throw Failure.unsafe }
        defer { close(fd) }
        var st=stat(),after=stat(),named=stat()
        guard fstat(fd,&st)==0, st.st_mode&S_IFMT==S_IFREG, st.st_uid==geteuid(), st.st_mode&0o7777==0o600, st.st_nlink==1, st.st_size > 0, st.st_size<=65536 else { throw Failure.unsafe }
        let file=FileHandle(fileDescriptor:fd,closeOnDealloc:false);var data=Data()
        while data.count<=65536 {
            let chunk=try file.read(upToCount:min(8192,65537-data.count)) ?? Data()
            if chunk.isEmpty { break };data.append(chunk)
        }
        guard data.count==st.st_size,fstat(fd,&after)==0,fstatat(dir,"models.toml",&named,AT_SYMLINK_NOFOLLOW)==0,
              after.st_dev==st.st_dev,after.st_ino==st.st_ino,after.st_size==st.st_size,after.st_mode==st.st_mode,after.st_uid==st.st_uid,after.st_nlink==st.st_nlink,
              after.st_mtimespec.tv_sec==st.st_mtimespec.tv_sec,after.st_mtimespec.tv_nsec==st.st_mtimespec.tv_nsec,
              named.st_dev==st.st_dev,named.st_ino==st.st_ino,let text=String(data:data,encoding:.utf8) else { throw Failure.unsafe }
        return text
    }
    func read() throws -> Snapshot {
        guard let fd=try directoryFD(create:false) else { return Snapshot(content:nil,name:"jev",existingKey:nil,enabled:true,endpoint:"",model:"") }
        defer { close(fd) }
        guard let text=try readFile(fd) else { return Snapshot(content:nil,name:"jev",existingKey:nil,enabled:true,endpoint:"",model:"") }
        do {
            let parsed=try ControlDecisionConfig.parseEditable(text)
            return Snapshot(content:text,name:parsed.name,existingKey:parsed.config.key,enabled:parsed.enabled,endpoint:parsed.config.endpoint.absoluteString,model:parsed.config.model)
        } catch { throw Failure.unsupported }
    }
    func save(_ snapshot: Snapshot, enabled: Bool, endpoint: String, model: String, newKey: String) throws {
        let key=newKey.isEmpty ? snapshot.existingKey ?? "" : newKey
        func quoted(_ value:String) throws -> String {
            let encoder=JSONEncoder();encoder.outputFormatting=[.withoutEscapingSlashes]
            return String(decoding:try encoder.encode(value),as:UTF8.self)
        }
        let replacements=["enabled":enabled ? "true" : "false","url":try quoted(endpoint),"model":try quoted(model),"api_key":try quoted(key)]
        var text: String
        if let original=snapshot.content {
            var lines=original.components(separatedBy:"\n"), section="", found=Set<String>(), end: Int?
            for i in lines.indices {
                let trimmed=lines[i].trimmingCharacters(in:.whitespacesAndNewlines)
                if trimmed.first=="[", trimmed.last=="]" {
                    if section==snapshot.name && end==nil { end=i }
                    section=String(trimmed.dropFirst().dropLast().dropFirst(7));continue
                }
                guard section==snapshot.name,let equal=trimmed.firstIndex(of:"=") else { continue }
                let name=trimmed[..<equal].trimmingCharacters(in:.whitespaces)
                if let value=replacements[name] { found.insert(name);lines[i]="\(name) = \(value)" + (lines[i].hasSuffix("\r") ? "\r" : "") }
            }
            let missing=["enabled","url","model","api_key"].filter{!found.contains($0)}.map{"\($0) = \(replacements[$0]!)"}
            lines.insert(contentsOf:missing,at:end ?? lines.count);text=lines.joined(separator:"\n")
        } else {
            text="default_model = \"jev\"\n\n[models.jev]\nenabled = \(replacements["enabled"]!)\nurl = \(replacements["url"]!)\nmodel = \(replacements["model"]!)\napi_key = \(replacements["api_key"]!)\n"
        }
        guard text.utf8.count<=65536 else { throw Failure.invalid }
        do { _ = try ControlDecisionConfig.parseEditable(text) } catch { throw Failure.invalid }
        guard let dir=try directoryFD(create:true) else { throw Failure.unsafe };defer { close(dir) }
        let lock=openat(dir,"config.lock",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard lock>=0 else { if errno==EEXIST { throw Failure.busy };throw Failure.unsafe }
        var lockStat=stat();guard fstat(lock,&lockStat)==0 else { close(lock);throw Failure.unsafe }
        defer {
            var named=stat();if fstatat(dir,"config.lock",&named,AT_SYMLINK_NOFOLLOW)==0 && named.st_dev==lockStat.st_dev && named.st_ino==lockStat.st_ino { _=unlinkat(dir,"config.lock",0) }
            close(lock)
        }
        guard try readFile(dir)==snapshot.content else { throw Failure.changed }
        let temp=".safarier-\(UUID().uuidString).tmp"
        let fd=openat(dir,temp,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else { throw Failure.unsafe }
        defer { close(fd);_=unlinkat(dir,temp,0) }
        guard fchmod(fd,0o600)==0 else { throw Failure.unsafe }
        let bytes=Array(text.utf8)
        let written=bytes.withUnsafeBytes { raw -> Bool in
            var offset=0
            while offset<raw.count { let n=Darwin.write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset);if n<=0 { return false };offset += n }
            return true
        }
        guard written,fsync(fd)==0,try readFile(dir)==snapshot.content else { throw Failure.changed }
        guard let current=try directoryFD(create:false) else { throw Failure.changed };defer { close(current) }
        var a=stat(),b=stat();guard fstat(dir,&a)==0,fstat(current,&b)==0,a.st_dev==b.st_dev,a.st_ino==b.st_ino else { throw Failure.changed }
        let result = snapshot.content == nil ? renameatx_np(dir,temp,dir,"models.toml",UInt32(RENAME_EXCL)) : renameat(dir,temp,dir,"models.toml")
        guard result==0 else { if errno == EEXIST { throw Failure.changed }; throw Failure.unsafe }
        guard fsync(dir)==0 else { throw Failure.committedUnconfirmed }
    }
}
