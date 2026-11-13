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
        _ = try await registered.takeReleasedOwner(matching: receipt)
        let transfers = await client.transfers, drains = await root.drains
        precondition(transfers == 3 && drains == 1, "dispatch must reach Core exactly once per call, then drain once")
        do {
            _ = try await registered.takeReleasedOwner(matching: receipt)
            fatalError("finished registered endpoint must reject a repeat")
        } catch {}
        let finalTransfers = await client.transfers, finalDrains = await root.drains
        precondition(finalTransfers == 3 && finalDrains == 1)
        print("PASS: concrete, protocol default, registered wrapper; exactly 3 Core calls / 1 drain; repeat rejected")
    }
}
