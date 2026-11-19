#if SAFARIER_BOUND_LOCAL_CANDIDATE
import CryptoKit
import Darwin
import Foundation

/// A private discovery address, never process ownership or authorization.
struct RegisteredRunnerRendezvous {
    let path: String
    private let directory: PrivateDirectoryPin

    init(workspace: SafarierWorkspace, profileID: UUID, pid: Int32, birth: UInt64, micros: UInt64) throws {
        guard pid > 1, birth > 0 else { throw IdentityBridgeError.rejected }
        let capacity = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard capacity > 1, capacity <= PATH_MAX else { throw IdentityBridgeError.rejected }
        var buffer = [CChar](repeating: 0, count: capacity)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, capacity) == capacity else { throw IdentityBridgeError.rejected }
        let root = URL(fileURLWithPath: String(cString: buffer), isDirectory: true).resolvingSymlinksInPath()
        let privateRoot = root.appendingPathComponent("sfr", isDirectory: true)
        guard mkdir(privateRoot.path, 0o700) == 0 || errno == EEXIST else { throw IdentityBridgeError.rejected }
        directory = try PrivateDirectoryPin(path: privateRoot)
        let key = "\(profileID.uuidString):\(pid):\(birth):\(micros):\(workspace.root.standardizedFileURL.path)"
        let name = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        path = privateRoot.appendingPathComponent(name).path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw IdentityBridgeError.rejected }
    }

    private func address() -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8) }
        return addr
    }

    private func socketFD() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AutomationChannel.ChannelError.systemCall(errno) }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno; close(fd); throw AutomationChannel.ChannelError.systemCall(code)
        }
        return fd
    }

    private func pin(requireMode: Bool = true) throws -> stat {
        var value = stat()
        guard directory.matches(), lstat(path, &value) == 0, value.st_uid == geteuid(), value.st_nlink == 1,
              value.st_mode & S_IFMT == S_IFSOCK, !requireMode || value.st_mode & 0o7777 == 0o600 else {
            throw IdentityBridgeError.rejected
        }
        return value
    }

    private func matches(_ expected: stat, requireMode: Bool = true) -> Bool {
        guard let actual = try? pin(requireMode: requireMode) else { return false }
        return actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino
    }

    func listen() throws -> Listener {
        guard directory.matches() else { throw IdentityBridgeError.rejected }
        let fd = try socketFD()
        var created: stat?
        do {
            var addr = address()
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { throw AutomationChannel.ChannelError.systemCall(errno) }
            let observed = try pin(requireMode: false); created = observed
            guard fchmodat(AT_FDCWD, path, 0o600, AT_SYMLINK_NOFOLLOW) == 0, matches(observed), Darwin.listen(fd, 4) == 0 else {
                throw IdentityBridgeError.rejected
            }
            return Listener(fd: fd, endpoint: self, created: observed)
        } catch {
            close(fd)
            if let created, matches(created, requireMode: false) { _ = unlink(path) }
            throw error
        }
    }

    func connect() throws -> AutomationChannel {
        let entry = try pin()
        let fd = try socketFD()
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var addr = address()
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw AutomationChannel.ChannelError.systemCall(errno) }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw AutomationChannel.ChannelError.systemCall(errno) }
        guard matches(entry), fcntl(fd, F_SETFL, 0) == 0 else { throw IdentityBridgeError.rejected }
        return try AutomationChannel(adopting: handle)
    }

    final class Listener: @unchecked Sendable {
        private let fd: Int32
        private let endpoint: RegisteredRunnerRendezvous
        private let created: stat
        private let queue = DispatchQueue(label: "Safarier.registered-reconnect.accept")
        fileprivate init(fd: Int32, endpoint: RegisteredRunnerRendezvous, created: stat) {
            self.fd = fd; self.endpoint = endpoint; self.created = created
        }
        deinit {
            close(fd)
            if endpoint.matches(created) { _ = unlink(endpoint.path) }
        }
        func accept() async throws -> AutomationChannel {
            try await withCheckedThrowingContinuation { resume in
                queue.async {
                    let accepted = Darwin.accept(self.fd, nil, nil)
                    guard accepted >= 0 else { resume.resume(throwing: AutomationChannel.ChannelError.systemCall(errno)); return }
                    let handle = FileHandle(fileDescriptor: accepted, closeOnDealloc: true)
                    do {
                        guard fcntl(accepted, F_SETFD, FD_CLOEXEC) == 0, self.endpoint.matches(self.created) else {
                            throw IdentityBridgeError.rejected
                        }
                        resume.resume(returning: try AutomationChannel(adopting: handle))
                    } catch { resume.resume(throwing: error) }
                }
            }
        }
    }
}
#endif
