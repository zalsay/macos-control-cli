import Foundation
import Darwin
import BinderIdentity

#if SAFARIER_BOUND_LOCAL_CANDIDATE
/// Transport only. The owner must authenticate its retained root peer before and
/// after each transfer and independently authenticate the newly received stream.
enum RegistrationDescriptorTransfer {
    enum Failure: Error { case invalidTimeout, invalidStream, transferFailed }
    static let maximumTimeout: Double = 5

    private static func deadline(_ seconds: Double) throws -> UInt64 {
        guard seconds.isFinite, seconds > 0, seconds <= maximumTimeout else { throw Failure.invalidTimeout }
        let milliseconds = UInt32((seconds * 1000).rounded(.down))
        let result = bi_deadline_after_ms(milliseconds)
        guard result != 0 else { throw Failure.invalidTimeout }
        return result
    }

    static func send(stream: FileHandle, descriptor: FileHandle, timeout: Double) throws {
        do {
            let end = try deadline(timeout)
            try AutomationChannel.validateConnectedStream(fileDescriptor: stream.fileDescriptor)
            try AutomationChannel.validateConnectedStream(fileDescriptor: descriptor.fileDescriptor)
            guard sfr_registration_send_fd(stream.fileDescriptor, descriptor.fileDescriptor, end) == 0 else { throw Failure.transferFailed }
        } catch {
            try? stream.close()
            throw error
        }
    }

    static func receive(stream: FileHandle, timeout: Double) throws -> FileHandle {
        do {
            let end = try deadline(timeout)
            try AutomationChannel.validateConnectedStream(fileDescriptor: stream.fileDescriptor)
            var fd: Int32 = -1
            guard sfr_registration_receive_fd(stream.fileDescriptor, &fd, end) == 0, fd >= 0 else { throw Failure.transferFailed }
            let received = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do { try AutomationChannel.validateConnectedStream(fileDescriptor: fd); return received }
            catch { try? received.close(); throw error }
        } catch {
            try? stream.close()
            throw error
        }
    }
}
#endif
