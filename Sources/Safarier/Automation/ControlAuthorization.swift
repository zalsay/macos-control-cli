import Foundation

/// Permission-only command policy. No workspace, browser request or retry.
enum ControlAuthorization {
    enum ArgumentError: Error { case usage }
    static func parse(_ arguments: [String]) throws -> Bool {
        if arguments.isEmpty { return false }
        if arguments == ["--request"] { return true }
        throw ArgumentError.usage
    }

    struct Reply {
        let status: String
        let osStatus: Int32?
        var statusDescription: String {
            switch status {
            case "allowed": return "当前宿主可向已核验 Manager 请求 SFAu/requ；未发送业务事件。"
            case "consent_required": return "需要用户同意；本次未获得授权。"
            case "not_permitted": return "系统未许可；可能是用户拒绝或系统策略，不自动重试。"
            case "target_changed": return "Manager 身份或唯一性未能保持；不得使用本次授权结果。"
            default:
                if osStatus == -1712 { return "权限只读查询等待超时；授权状态未知，未发送业务事件。" }
                return "目标或权限查询不可用；未发送业务事件。"
            }
        }
        func jsonData() throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "status": status, "statusDescription": statusDescription,
                "osStatus": osStatus.map { NSNumber(value: $0) } ?? NSNull(),
                "businessEventSent": false
            ], options: [.sortedKeys])
        }
    }

    /// The system permission API cannot be cancelled. Only the first result may
    /// complete a read-only query; a late native result is discarded.
    @MainActor private final class PendingQuery {
        private var continuation: CheckedContinuation<(Int32, Bool)?, Never>?
        var timer: Task<Void, Never>?
        init(_ continuation: CheckedContinuation<(Int32, Bool)?, Never>) {
            self.continuation = continuation
        }
        func finish(_ result: (Int32, Bool)?) {
            guard let continuation else { return }
            self.continuation = nil
            timer?.cancel()
            timer = nil
            continuation.resume(returning: result)
        }
    }

    // The production caller supplies its retained NSRunningApplication checks.
    // Tests substitute only these dependencies, never production identity gates.
    @MainActor static func perform(request: Bool, targetCurrent: () -> Bool,
                                   permission: @escaping @MainActor (Bool) async -> (Int32, Bool)) async -> Reply {
        guard targetCurrent() else { return Reply(status: "target_changed", osStatus: nil) }
        let result: (Int32, Bool)?
        if request {
            result = await permission(true)
        } else {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            result = await withCheckedContinuation { continuation in
                let pending = PendingQuery(continuation)
                pending.timer = Task {
                    do { try await Task.sleep(until: deadline, clock: .continuous) }
                    catch { return }
                    pending.finish(nil)
                }
                Task {
                    let value = await permission(false)
                    pending.finish(ContinuousClock.now < deadline ? value : nil)
                }
            }
        }
        // Do not wait for another synchronous identity capture after the API
        // stalls: no permission result is being accepted on this path.
        guard let (code, changed) = result else { return Reply(status: "unavailable", osStatus: -1712) }
        let current = targetCurrent()
        guard current && !changed else { return Reply(status: "target_changed", osStatus: code) }
        let status: String
        switch code {
        case 0: status = "allowed"
        case -1744: status = "consent_required"
        case -1743: status = "not_permitted"
        default: status = "unavailable"
        }
        return Reply(status: status, osStatus: code)
    }
}
