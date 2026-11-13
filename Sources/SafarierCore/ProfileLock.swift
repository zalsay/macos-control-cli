import Foundation

/// 同一个 profile 同时只允许一个 Runner 进程：两个进程打开同一个持久 DataStore 会互相踩数据。
/// 用 `flock` 实现，进程退出（包括崩溃）时内核自动释放。
public final class ProfileLock {
    public let fileURL: URL
    private var descriptor: Int32
    private let candidateAcquisition: Bool
    private let mutex = NSLock()
    private var releaseRequested = false
    private var loanActive = false
    private var revokeLoan: (() -> Void)?

    private init(fileURL: URL, descriptor: Int32, candidateAcquisition: Bool) {
        self.fileURL = fileURL
        self.descriptor = descriptor
        self.candidateAcquisition = candidateAcquisition
    }

    deinit {
        release()
    }

    /// 已被其它进程持有时抛 `ProfileLockError.alreadyRunning`。
    public static func acquire(profileID: UUID, in directory: URL) throws -> ProfileLock {
        try acquireChecked(profileID: profileID, in: directory, candidate: false)
    }

    /// Candidate launch must call this before constructing native resources. This
    /// does not grant automation; it only acquires a safely inspected file lock.
    public static func acquireForBoundCandidate(profileID: UUID, in directory: URL) throws -> ProfileLock {
        try acquireChecked(profileID: profileID, in: directory, candidate: true)
    }

    private static func acquireChecked(profileID: UUID, in directory: URL, candidate: Bool) throws -> ProfileLock {
        var rootPin: PrivateDirectoryPin?, locksPin: PrivateDirectoryPin?
        if candidate {
            do {
                rootPin = try PrivateDirectoryPin(path: directory.deletingLastPathComponent())
                locksPin = try PrivateDirectoryPin(path: directory)
            } catch { throw ProfileLockError.unsafeFile(directory.path) }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let url = directory.appendingPathComponent("\(profileID.uuidString).lock")
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ProfileLockError.cannotOpen(url.path, errno) }
        func safeAndSame() -> Bool {
            var held = stat(), named = stat()
            guard fstat(fd, &held) == 0, lstat(url.path, &named) == 0 else { return false }
            guard (held.st_mode & S_IFMT) == S_IFREG, (named.st_mode & S_IFMT) == S_IFREG,
                  held.st_uid == geteuid(), named.st_uid == geteuid(),
                  held.st_nlink == 1, named.st_nlink == 1,
                  held.st_dev == named.st_dev, held.st_ino == named.st_ino else { return false }
            if candidate {
                guard (held.st_mode & 0o7777) == 0o600, (named.st_mode & 0o7777) == 0o600,
                      rootPin?.matches() == true, locksPin?.matches() == true else { return false }
            }
            return true
        }
        guard safeAndSame() else { close(fd); throw ProfileLockError.unsafeFile(url.path) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; close(fd)
            if code == EWOULDBLOCK { throw ProfileLockError.alreadyRunning(profileID) }
            throw ProfileLockError.cannotLock(url.path, code)
        }
        guard safeAndSame() else { flock(fd, LOCK_UN); close(fd); throw ProfileLockError.unsafeFile(url.path) }
        let pid = "\(getpid())\n"
        guard ftruncate(fd, 0) == 0 else {
            let code = errno; flock(fd, LOCK_UN); close(fd); throw ProfileLockError.cannotWrite(url.path, code)
        }
        let written = pid.withCString { write(fd, $0, strlen($0)) }
        guard written == pid.utf8.count else {
            let code = errno; flock(fd, LOCK_UN); close(fd); throw ProfileLockError.cannotWrite(url.path, code)
        }
        return ProfileLock(fileURL: url, descriptor: fd, candidateAcquisition: candidate)
    }

    /// 只检查不加锁，供 Manager 显示运行状态、拒绝删除正在运行的 profile。
    public static func isHeld(profileID: UUID, in directory: URL) -> Bool {
        let url = directory.appendingPathComponent("\(profileID.uuidString).lock")
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// 持有者写进锁文件的 pid；没被持有（或持有者还没写完）时返回 nil。
    public static func holderPID(profileID: UUID, in directory: URL) -> Int32? {
        guard isHeld(profileID: profileID, in: directory) else { return nil }
        let url = directory.appendingPathComponent("\(profileID.uuidString).lock")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A loan retains this exact locked open file description, never exposes its fd,
    /// and prevents release from unlocking before the borrower has drained.
    final class Lease {
        private let owner: ProfileLock
        private let mutex = NSLock()
        private var returned = false
        fileprivate init(owner: ProfileLock) { self.owner = owner }
        func check() -> Bool {
            mutex.lock(); defer { mutex.unlock() }
            return !returned && owner.loanIsValid()
        }
        func setRevocation(_ callback: @escaping () -> Void) {
            owner.setLoanRevocation(callback)
        }
        func finish() {
            mutex.lock(); defer { mutex.unlock() }
            guard !returned else { return }
            returned = true
            owner.returnLoan()
        }
        deinit { finish() }
    }

    func borrow(profileID: UUID, directory: URL) throws -> Lease {
        mutex.lock(); defer { mutex.unlock() }
        let expected = directory.appendingPathComponent("\(profileID.uuidString).lock")
        guard candidateAcquisition, fileURL.standardizedFileURL == expected.standardizedFileURL,
              !releaseRequested, !loanActive, matchesHeldFileLocked() else {
            throw ProfileLockError.loanUnavailable
        }
        loanActive = true
        return Lease(owner: self)
    }

    private func matchesHeldFileLocked() -> Bool {
        guard descriptor >= 0 else { return false }
        var held = stat(), path = stat()
        guard fstat(descriptor, &held) == 0, lstat(fileURL.path, &path) == 0 else { return false }
        return (held.st_mode & S_IFMT) == S_IFREG && (path.st_mode & S_IFMT) == S_IFREG &&
            (held.st_mode & 0o7777) == 0o600 && (path.st_mode & 0o7777) == 0o600 &&
            held.st_uid == geteuid() && path.st_uid == geteuid() &&
            held.st_nlink == 1 && path.st_nlink == 1 &&
            held.st_dev == path.st_dev && held.st_ino == path.st_ino
    }
    private func setLoanRevocation(_ callback: @escaping () -> Void) {
        mutex.lock()
        if loanActive && !releaseRequested { revokeLoan = callback; mutex.unlock() }
        else { mutex.unlock(); callback() }
    }
    private func loanIsValid() -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        return loanActive && !releaseRequested && matchesHeldFileLocked()
    }
    private func unlockLocked() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1
    }
    private func returnLoan() {
        mutex.lock(); defer { mutex.unlock() }
        guard loanActive else { return }
        loanActive = false
        revokeLoan = nil
        if releaseRequested { unlockLocked() }
    }
    public func release() {
        mutex.lock()
        releaseRequested = true
        let callback = revokeLoan
        if !loanActive { unlockLocked() }
        mutex.unlock()
        callback?()
    }

}

public enum ProfileLockError: Error, Equatable {
    case unsafeFile(String)
    case cannotWrite(String, Int32)
    case loanUnavailable
    case alreadyRunning(UUID)
    case cannotOpen(String, Int32)
    case cannotLock(String, Int32)
}
