import Foundation
import Darwin



/// A private, connected Unix stream, carrying opaque length-prefixed frames.
/// Cancellation closes the entire channel, waking both readers and writers.
public final class AutomationChannel: @unchecked Sendable {
    public static let maximumFrameBytes = 65_536
    /// Includes the four-byte header for each queued or in-flight frame.
    public static let maximumPendingSendBytes = 4 * (maximumFrameBytes + 4)
    public enum ChannelError: Error {
        case closed, invalidSocket, invalidFrameLength, sendBackpressure, truncatedFrame, readerConflict, systemCall(Int32)
    }

    // Diagnostic labels only: not routing, authority or lifecycle state.
    enum RegistrationDiagnosticRole: String { case rootManager, rootRunner, generationManager, generationRunner }
    enum CloseDiagnosticOrigin: String { case explicitClose, readerLeaseDeinit, channelDeinit, deadlineFailure, cancellation, operationFailure }
    static func failureCloseOrigin(_ error: Error) -> CloseDiagnosticOrigin {
        if error is CancellationError { return .cancellation }
        if let error = error as? HarnessError {
            switch error { case .deadline, .invalidClock: return .deadlineFailure; default: break }
        }
        if let error = error as? AutomationError, error.code == .timeout { return .deadlineFailure }
        return .operationFailure
    }
    private struct CloseTrace {
        let role: RegistrationDiagnosticRole
        let origin: CloseDiagnosticOrigin
        let monotonicNanoseconds: UInt64
        let fileID: StaticString, line: UInt, function: StaticString
    }
    private static func emitClose(_ trace: CloseTrace?) {
        guard let trace else { return }
        RootIdentityDiagnostic.emit("CHANNEL_CLOSE_DIAG role=\(trace.role.rawValue) origin=\(trace.origin.rawValue) file=\(trace.fileID) line=\(trace.line) function=\(trace.function)",
                                    monotonicNanoseconds: trace.monotonicNanoseconds)
    }
    private var registrationDiagnosticRole: RegistrationDiagnosticRole?
    func labelRegistration(_ role: RegistrationDiagnosticRole) {
        lock.lock(); registrationDiagnosticRole = role; lock.unlock()
    }

    private let lock = NSLock()
    private var descriptor: Int32
    private var pendingSendBytes = 0
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    private var registrationTransferActive = false
    #endif
    private var legacyReaders = 0
    private var leaseID: UUID?
    private var leasedReadActive = false
    private weak var fixtureWriterBinding: FixtureWriterBinding?
    private var fixtureWasBound = false
    // Only the existing writeQueue accesses these fields.
    private var writeJobs: [WriteJob] = []

    public final class ReaderLease: @unchecked Sendable {
        private let channel: AutomationChannel
        fileprivate let id: UUID
        fileprivate init(channel: AutomationChannel, id: UUID) { self.channel = channel; self.id = id }
        public func receive() async throws -> Data? { try await channel.receiveImpl(lease: id) }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        func receiveRegisteredDescriptor(timeout: Double) async throws -> FileHandle {
            try await channel.receiveRegisteredDescriptor(lease: id, timeout: timeout)
        }
        #endif
        @_disfavoredOverload public func close() { channel.close() }
        public func close(fileID: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
            channel.close(fileID: fileID, line: line, function: function)
        }
        deinit { channel.close(origin: .readerLeaseDeinit) }
    }
    public func claimExclusiveReader() throws -> ReaderLease {
        lock.lock()
        guard descriptor >= 0 else { lock.unlock(); throw ChannelError.closed }
        guard legacyReaders == 0, leaseID == nil else {
            let trace = closeLocked(); lock.unlock(); Self.emitClose(trace); close(); throw ChannelError.readerConflict
        }
        let id = UUID(); leaseID = id
        lock.unlock()
        return ReaderLease(channel: self, id: id)
    }
    // Fixture-only: derive inspector from this channel, never from a caller-provided socket.
    func duplicateInspector() throws -> FileHandle {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { throw ChannelError.closed }
        let fd = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw ChannelError.systemCall(errno) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    private func admitRead(_ id: UUID?) throws {
        lock.lock()
        guard descriptor >= 0 else { lock.unlock(); throw ChannelError.closed }
        if let id {
            guard leaseID == id, !leasedReadActive else {
                let trace = closeLocked(); lock.unlock(); Self.emitClose(trace); close(); throw ChannelError.readerConflict
            }
            leasedReadActive = true
        } else {
            guard leaseID == nil else {
                let trace = closeLocked(); lock.unlock(); Self.emitClose(trace); close(); throw ChannelError.readerConflict
            }
            legacyReaders += 1
        }
        lock.unlock()
    }
    private func finishRead(_ id: UUID?) {
        lock.lock(); defer { lock.unlock() }
        if id != nil { leasedReadActive = false } else { legacyReaders -= 1 }
    }
    private let readQueue = DispatchQueue(label: "Safarier.AutomationChannel.read")
    private let writeQueue = DispatchQueue(label: "Safarier.AutomationChannel.write")

    public static func makePair() throws -> (parent: AutomationChannel, child: FileHandle) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw ChannelError.systemCall(errno) }
        do {
            try configure(fds[0]); try configure(fds[1])
            let handle = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
            fds[0] = -1
            let parent = try AutomationChannel(adopting: handle)
            let child = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
            fds[1] = -1
            return (parent, child)
        } catch {
            if fds[0] >= 0 { Darwin.close(fds[0]) }
            if fds[1] >= 0 { Darwin.close(fds[1]) }
            throw error
        }
    }

    /// On success consumes the supplied handle. On failure it remains owned by the caller.
    public init(adopting handle: FileHandle) throws {
        let fd = handle.fileDescriptor
        try Self.validateConnectedStream(fileDescriptor: fd)
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw ChannelError.systemCall(errno) }
        do { try Self.configure(copy); try handle.close() }
        catch { Darwin.close(copy); throw error }
        descriptor = copy
    }

    public static func validateConnectedStream(fileDescriptor fd: Int32) throws {
        var kind: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard fd >= 0, getsockopt(fd, SOL_SOCKET, SO_TYPE, &kind, &size) == 0,
              kind == SOCK_STREAM else { throw ChannelError.invalidSocket }
        var address = sockaddr_storage()
        var addressSize = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let local = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &addressSize) } }
        guard local == 0, Int32(address.ss_family) == AF_UNIX else { throw ChannelError.invalidSocket }
        addressSize = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let peer = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &addressSize) } }
        guard peer == 0, Int32(address.ss_family) == AF_UNIX else { throw ChannelError.invalidSocket }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, flags & O_ACCMODE == O_RDWR else { throw ChannelError.invalidSocket }
    }

    private static func configure(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else { throw ChannelError.systemCall(errno) }
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw ChannelError.systemCall(errno) }
    }

    // A duplicated descriptor remains valid independently of close(); shutdown of
    // the shared socket wakes blocking calls before either descriptor is released.
    private func operationFD() throws -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { throw ChannelError.closed }
        let fd = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw ChannelError.systemCall(errno) }
        return fd
    }
    private func closeLocked(origin: CloseDiagnosticOrigin = .explicitClose, fileID: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) -> CloseTrace? {
        if descriptor >= 0 {
            let trace = registrationDiagnosticRole.map {
                CloseTrace(role: $0, origin: origin, monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds, fileID: fileID, line: line, function: function)
            }
            _ = shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            descriptor = -1
            return trace
        }
        return nil
    }
    // A negative hint only: queued data without HUP does not prove peer liveness.
    func observedDisconnect() throws -> Bool {
        let fd = try operationFD(); defer { Darwin.close(fd) }
        var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let n = Darwin.poll(&item, 1, 0)
        if n < 0 { throw ChannelError.systemCall(errno) }
        if item.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        if item.revents & Int16(POLLIN) != 0 {
            var byte: UInt8 = 0
            let result = Darwin.recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if result == 0 { return true }
            if result < 0 && errno != EAGAIN && errno != EWOULDBLOCK { throw ChannelError.systemCall(errno) }
        }
        return false
    }
    @_disfavoredOverload public func close() { close(origin: .explicitClose) }
    public func close(fileID: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        close(origin: .explicitClose, fileID: fileID, line: line, function: function)
    }
    func close(origin: CloseDiagnosticOrigin, fileID: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        lock.lock(); let trace = closeLocked(origin: origin, fileID: fileID, line: line, function: function); lock.unlock(); Self.emitClose(trace)
        writeQueue.async { self.failWriteJobs(ChannelError.closed) }
    }
    deinit { lock.lock(); let trace = closeLocked(origin: .channelDeinit); lock.unlock(); Self.emitClose(trace) }

    private func reserveSend(_ count: Int) throws {
        var trace: CloseTrace?
        lock.lock(); defer { lock.unlock(); Self.emitClose(trace) }
        guard descriptor >= 0 else { throw ChannelError.closed }
        #if SAFARIER_BOUND_LOCAL_CANDIDATE
        guard !registrationTransferActive else { throw ChannelError.sendBackpressure }
        #endif
        guard !fixtureWasBound else { trace = closeLocked(); throw ChannelError.closed }
        guard count <= Self.maximumPendingSendBytes - pendingSendBytes else { throw ChannelError.sendBackpressure }
        pendingSendBytes += count
    }
    private func releaseSend(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        pendingSendBytes -= count
    }

    func requireOpen(before deadline: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0, DispatchTime.now().uptimeNanoseconds < deadline else { throw ChannelError.closed }
    }
    // Concrete binding and sealed frames are minted only by the server file.
    func installFixtureWriter(_ binding: FixtureWriterBinding) throws {
        var trace: CloseTrace?
        lock.lock()
        let valid = descriptor >= 0 && !fixtureWasBound && pendingSendBytes == 0 &&
            binding.channel === self && leaseID == binding.reader.id
        if valid { fixtureWasBound = true; fixtureWriterBinding = binding }
        else { trace = closeLocked() }
        lock.unlock(); Self.emitClose(trace)
        guard valid else { close(); throw ChannelError.closed }
    }

    func isLocallyOpen() -> Bool { lock.lock(); defer { lock.unlock() }; return descriptor >= 0 }
    private func isOwnedBinding(_ binding: FixtureWriterBinding) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return descriptor >= 0 && fixtureWasBound && fixtureWriterBinding === binding &&
            binding.channel === self && leaseID == binding.reader.id
    }
    private func reserveBound(_ count: Int, binding: FixtureWriterBinding) throws {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0, fixtureWasBound, fixtureWriterBinding === binding,
              binding.channel === self, leaseID == binding.reader.id else { throw ChannelError.closed }
        guard count <= Self.maximumPendingSendBytes - pendingSendBytes else { throw ChannelError.sendBackpressure }
        pendingSendBytes += count
    }

    // Both legacy and bound frames use this same queue-owned FIFO and writer.
    private final class WriteJob: @unchecked Sendable {
        let admission: SealedWriteAdmission?
        let cutoff: UInt64?
        let framed: Data
        let reservedBytes: Int
        let continuation: CheckedContinuation<Void, Error>
        var offset = 0
        var receipt = 0
        var validatorTask: Task<Void, Never>?
        var terminal = false
        var testHeadObserved = false
        init(frame: Data, admission: SealedWriteAdmission?, cutoff: UInt64?, continuation: CheckedContinuation<Void, Error>) {
            self.admission = admission; self.cutoff = cutoff; self.continuation = continuation
            let n = UInt32(frame.count)
            var data = Data([UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
            data.append(frame); framed = data; reservedBytes = data.count
        }
    }
    private func legacyStillAllowed() -> Bool {
        lock.lock(); defer { lock.unlock() }; return descriptor >= 0 && !fixtureWasBound
    }
    private func rejectBoundAliasIfNeeded() throws {
        lock.lock(); let bound = fixtureWasBound; lock.unlock()
        if bound { close(); throw ChannelError.closed }
    }
    func sendBound(_ admission: SealedWriteAdmission) async throws {
        guard isOwnedBinding(admission.binding) else { close(); throw ChannelError.closed }
        guard admission.claim() else { close(); throw ChannelError.closed }
        defer { admission.finishDeadline() }
        guard !admission.frame.isEmpty, admission.frame.count <= Self.maximumFrameBytes else { close(); throw ChannelError.invalidFrameLength }
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            do { try self.reserveBound(admission.frame.count + 4, binding: admission.binding) }
            catch ChannelError.sendBackpressure where admission.binding.isController {
                try Task.checkCancellation()
                try admission.binding.checkCommit()
                guard self.isOwnedBinding(admission.binding), DispatchTime.now().uptimeNanoseconds < admission.cutoff else {
                    self.close(); throw ChannelError.closed
                }
                throw ChannelError.sendBackpressure
            } catch { self.close(); throw error }
            try await self.enqueueWrite(frame: admission.frame, admission: admission, cutoff: admission.cutoff)
        }, onCancel: { self.close(origin: .cancellation) })
    }
    public func send(_ frame: Data) async throws { try await sendImpl(frame, expiresAt: nil) }
    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    /// Root registration only: caller authenticates before and after this transfer.
    /// A transfer is exclusive with framed sends and never retried on failure.
    func sendRegisteredDescriptor(_ handle: FileHandle, timeout: Double) async throws {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let copy = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0 else { close(); throw ChannelError.systemCall(errno) }
            let retained = FileHandle(fileDescriptor: copy, closeOnDealloc: true)
            defer { try? retained.close() }
            lock.lock()
            let admitted = descriptor >= 0 && !fixtureWasBound && pendingSendBytes == 0 && !registrationTransferActive
            if admitted { registrationTransferActive = true }
            lock.unlock()
            guard admitted else { close(); throw ChannelError.closed }
            defer { lock.lock(); registrationTransferActive = false; lock.unlock() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writeQueue.async {
                    do {
                        let fd = try self.operationFD()
                        let stream = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                        defer { try? stream.close() }
                        try RegistrationDescriptorTransfer.send(stream: stream, descriptor: retained, timeout: timeout)
                        continuation.resume()
                    } catch { self.close(); continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.close(origin: .cancellation) })
    }
    private func receiveRegisteredDescriptor(lease: UUID, timeout: Double) async throws -> FileHandle {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try admitRead(lease)
            defer { finishRead(lease) }
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FileHandle, Error>) in
                readQueue.async {
                    do {
                        let fd = try self.operationFD()
                        let stream = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                        defer { try? stream.close() }
                        let received = try RegistrationDescriptorTransfer.receive(stream: stream, timeout: timeout)
                        continuation.resume(returning: received)
                    } catch { self.close(); continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.close(origin: .cancellation) })
    }
    #endif
    func sendLeased(_ frame: Data, expiresAt: UInt64) async throws { try await sendImpl(frame, expiresAt: expiresAt) }
    private func sendImpl(_ frame: Data, expiresAt: UInt64?) async throws {
        try rejectBoundAliasIfNeeded()
        guard !frame.isEmpty, frame.count <= Self.maximumFrameBytes else { throw ChannelError.invalidFrameLength }
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            do { try self.reserveSend(frame.count + 4) } catch { if !self.isLocallyOpen() { self.close() }; throw error }
            try await self.enqueueWrite(frame: frame, admission: nil, cutoff: expiresAt)
        }, onCancel: { self.close(origin: .cancellation) })
    }
    private func enqueueWrite(frame: Data, admission: SealedWriteAdmission?, cutoff: UInt64?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let job = WriteJob(frame: frame, admission: admission, cutoff: cutoff, continuation: continuation)
            writeQueue.async {
                let ownerValid = admission.map { self.isOwnedBinding($0.binding) } ?? self.legacyStillAllowed()
                guard ownerValid, cutoff.map({ DispatchTime.now().uptimeNanoseconds < $0 }) ?? true else {
                    self.finishWrite(job, .failure(ChannelError.closed)); return
                }
                self.writeJobs.append(job)
                if self.writeJobs.count == 1 { self.advanceWriteHead(job) }
            }
        }
    }
    private func finishWrite(_ job: WriteJob, _ result: Result<Void, Error>) {
        guard !job.terminal else { return }
        job.terminal = true
        job.validatorTask?.cancel(); job.validatorTask = nil
        releaseSend(job.reservedBytes)
        job.continuation.resume(with: result)
    }
    private func failWriteJobs(_ error: Error) {
        let jobs = writeJobs; writeJobs.removeAll()
        for job in jobs { finishWrite(job, .failure(error)) }
    }
    private func advanceWriteHead(_ job: WriteJob) {
        guard writeJobs.first === job, !job.terminal else { return }
        guard job.cutoff.map({ DispatchTime.now().uptimeNanoseconds < $0 }) ?? true else {
            close(); failWriteJobs(ChannelError.closed); return
        }
        guard let admission = job.admission else {
            guard legacyStillAllowed() else { close(); failWriteJobs(ChannelError.closed); return }
            attemptWriteHead(job); return
        }
        guard isOwnedBinding(admission.binding) else { close(); failWriteJobs(ChannelError.closed); return }
        job.receipt += 1; let receipt = job.receipt, binding = admission.binding
        job.validatorTask = Task.detached { [weak self, weak job] in
            let result: Result<Void, Error>
            do {
                try await binding.validateOwnedQueuedWrite(admission)
                result = .success(())
            } catch { result = .failure(error) }
            guard let self, let job else {
                return
            }
            self.writeQueue.async {
                guard self.writeJobs.first === job, !job.terminal, job.receipt == receipt else {
                    return
                }
                job.validatorTask = nil
                guard self.isOwnedBinding(binding), DispatchTime.now().uptimeNanoseconds < admission.cutoff else {
                    self.close(); self.failWriteJobs(ChannelError.closed); return
                }
                switch result {
                case .failure(let error): self.close(); self.failWriteJobs(error)
                case .success: self.attemptWriteHead(job)
                }
            }
        }
    }
    private func physicalWriteAttempt(_ job: WriteJob) throws -> (Int, Int32) {
        if let cutoff = job.cutoff { try requireOpen(before: cutoff) }
        if let admission = job.admission {
            // Same concrete revocation record; no channel lock is held here.
            try admission.binding.checkCommit()
        }
        let fd = try operationFD(); defer { Darwin.close(fd) }
        return job.framed.withUnsafeBytes { buffer in
            let count = buffer.count - job.offset
            let result = Darwin.write(fd, buffer.baseAddress!.advanced(by: job.offset), count)
            let writeError = errno
            return (result, writeError)
        }
    }
    private func attemptWriteHead(_ job: WriteJob) {
        do {
            let (result, writeError) = try physicalWriteAttempt(job)
            if let cutoff = job.cutoff { try requireOpen(before: cutoff) }
            if result < 0 && writeError == EINTR { writeQueue.async { self.advanceWriteHead(job) }; return }
            guard result > 0 else { throw ChannelError.systemCall(result < 0 ? writeError : EPIPE) }
            job.offset += result
            if job.offset < job.framed.count { writeQueue.async { self.advanceWriteHead(job) }; return }
            writeJobs.removeFirst(); finishWrite(job, .success(()))
            if let next = writeJobs.first { writeQueue.async { self.advanceWriteHead(next) } }
        } catch { close(); failWriteJobs(error) }
    }

    public func receive() async throws -> Data? { try await receiveImpl(lease: nil) }
    private func receiveImpl(lease: UUID?) async throws -> Data? {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try admitRead(lease)
            defer { finishRead(lease) }
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                readQueue.async {
                    do {
                        let fd = try self.operationFD(); defer { Darwin.close(fd) }
                        func readBytes(_ count: Int, boundary: Bool) throws -> Data? {
                            var data = Data(count: count)
                            var offset = 0
                            try data.withUnsafeMutableBytes { buffer in
                                while offset < count {
                                    let result = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                                    if result < 0 && errno == EINTR { continue }
                                    if result < 0 { throw ChannelError.systemCall(errno) }
                                    if result == 0 {
                                        if boundary && offset == 0 { return }
                                        throw ChannelError.truncatedFrame
                                    }
                                    offset += result
                                }
                            }
                            return offset == 0 && boundary ? nil : data
                        }
                        guard let header = try readBytes(4, boundary: true) else { continuation.resume(returning: nil); return }
                        let length = header.reduce(0) { ($0 << 8) | Int($1) }
                        guard length > 0, length <= Self.maximumFrameBytes else { throw ChannelError.invalidFrameLength }
                        continuation.resume(returning: try readBytes(length, boundary: false))
                    } catch { self.close(); continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.close(origin: .cancellation) })
    }
}
