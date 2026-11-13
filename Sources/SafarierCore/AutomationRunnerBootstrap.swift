import Foundation
import Darwin

public enum AutomationRunnerBootstrap {
    public static func serveUnavailable(profileID: UUID, channel: AutomationChannel, idleSeconds: Double = AutomationLimits.idleSeconds) async -> Int32 {
        let server = AutomationRunnerServer(profileID: profileID, channel: channel, idleSeconds: idleSeconds, handler: { request in
            if case .capabilities = request.action {
                let caps = AutomationCapabilities(backend: .unavailable, uiPolicy: .unverified, coldLaunch: .unverified, version: "1", role: "runner", managerPID: Int(getppid()))
                return .success(.capabilities(caps))
            }
            return .failure(AutomationError(code: .backendUnavailable))
        }, shutdown: {})
        return await server.serve()
    }
}
