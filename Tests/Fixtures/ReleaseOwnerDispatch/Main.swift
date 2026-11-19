import Foundation
import SafarierCore
@main struct ReleaseDispatchRegression {
    static func main() async throws {
        let client = AutomationRunnerClient(), receipt = ControlReleaseReceipt()
        _ = try await client.takeValidatedReleasedOwner(matching: receipt)
        let endpoint: any AutomationManagerEndpoint = client
        _ = try await endpoint.takeReleasedOwner(matching: receipt)
        let root = RegisteredRunnerChannel()
        let registered: any AutomationManagerEndpoint = RegisteredManagerEndpoint(client: client, registered: root, epoch: UUID())
        try await registered.finishRegisteredRelease(matching: receipt)
        do {
            try await registered.finishRegisteredRelease(matching: receipt)
            fatalError("finished registered endpoint must reject a repeat")
        } catch {}
        do {
            _ = try await registered.takeReleasedOwner(matching: receipt)
            fatalError("registered browser must not grant ownership")
        } catch {}
        let transfers = await client.transfers, borrowedReleases = await client.borrowedReleases, drains = await root.drains
        precondition(transfers == 2 && borrowedReleases == 1 && drains == 1)
        print("PASS: owned release transfers its child; registered release drains without transferring authority; repeat rejected")
    }
}
