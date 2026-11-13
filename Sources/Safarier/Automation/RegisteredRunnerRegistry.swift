#if SAFARIER_BOUND_LOCAL_CANDIDATE
import Foundation
import OSLog
import SafarierCore

/// Manager-owned original children only. Never discovers or adopts a PID.
@MainActor final class RegisteredRunnerRegistry {
    private final class Entry {
        let owner: OwnedRunnerProcess
        let channel: AutomationChannel
        let spec: RunnerLaunchSpec
        let environment: [String: String]
        let ready: Task<RegisteredRunnerChannel, Error>
        init(owner: OwnedRunnerProcess, channel: AutomationChannel, spec: RunnerLaunchSpec, environment: [String: String], profileID: UUID) {
            self.owner = owner; self.channel = channel; self.spec = spec; self.environment = environment
            self.ready = Task {
                let started = DispatchTime.now().uptimeNanoseconds
                Self.trace("start", owner: owner, started: started)
                do {
                    let root = try await RegisteredRunnerChannel.establish(owner: owner, channel: channel, profileID: profileID)
                    Self.trace("ready", owner: owner, started: started)
                    return root
                } catch {
                    let kind: String
                    if let value = error as? AutomationError { kind = value.code.rawValue }
                    else if error is CancellationError { kind = "cancelled" }
                    else { kind = "rejected" }
                    Self.trace(kind, owner: owner, started: started)
                    throw error
                }
            }
        }
        private static func trace(_ result: String, owner: OwnedRunnerProcess, started: UInt64) {
            let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            let exit = owner.observedExit
            // Fixed stages/error enums and original owned exit only. Never paths,
            // profile data, arguments, tokens, or arbitrary error descriptions.
            let message = "REGISTERED_DIAG phase=root_establish result=\(result) elapsed_ms=\(elapsed) ownerRunning=\(owner.isRunning) exitObserved=\(exit != nil) exitStatus=\(exit.map { String($0.status) } ?? "unobserved") signalled=\(exit?.uncaughtSignal ?? false)"
            fputs(message + "\n", stderr)
            Logger(subsystem: "sh.safarier", category: "registered-root").notice("\(message, privacy: .public)")
        }
    }
    private let workspace: SafarierWorkspace
    private var entries: [UUID: Entry] = [:]
    init(workspace: SafarierWorkspace) { self.workspace = workspace }

    func contains(_ id: UUID) -> Bool { entries[id]?.owner.isRunning == true }
    func forgetExited(_ id: UUID) {
        guard let entry = entries[id], !entry.owner.isRunning else { return }
        entry.channel.close(); entries.removeValue(forKey: id)
    }

    func launch(_ profile: Profile, launcher: RunnerLauncher? = nil, initialBlank: Bool = false, url: URL? = nil, spiOverride: SPIFeatures? = nil, nonActivatingPresentation: Bool = false) throws {
        forgetExited(profile.id)
        guard entries[profile.id] == nil, !workspace.isRunning(profile.id) else { throw WorkspaceError.alreadyRunning(profile.id) }
        let pair = try AutomationChannel.makePair()
        do {
            let owner = try workspace.launchOwnedInteractive(profile, launcher: launcher, registrationInput: pair.child, initialBlank: initialBlank, url: url, spiOverride: spiOverride, nonActivatingPresentation: nonActivatingPresentation)
            try pair.child.close()
            let startURL = url ?? (initialBlank && profile.startURL == nil ? URL(string: "about:blank") : nil)
            var spec = workspace.runnerSpec(for: profile, url: startURL, spiOverride: spiOverride)
            spec.registeredInteractive = true
            spec.nonActivatingPresentation = nonActivatingPresentation
            var base = ProcessInfo.processInfo.environment; base["SAFARIER_HOME"] = workspace.root.path
            let entry = Entry(owner: owner, channel: pair.parent, spec: spec, environment: spec.environment(inheriting: base), profileID: profile.id)
            entries[profile.id] = entry
        } catch { pair.parent.close(); try? pair.child.close(); throw error }
    }

    func open(_ profile: Profile) async throws -> any AutomationManagerEndpoint {
        guard let entry = entries[profile.id], entry.owner.isRunning else { throw AutomationError(code: .profileAlreadyRunning) }
        let registered = try await entry.ready.value
        guard entries[profile.id] === entry, entry.owner.isRunning else { throw AutomationError(code: .runnerExited) }
        let opened = try await registered.openClient(workspace: workspace, spec: entry.spec, environment: entry.environment)
        return RegisteredManagerEndpoint(client: opened.client, registered: registered, epoch: opened.epoch)
    }
}

actor RegisteredManagerEndpoint: AutomationManagerEndpoint {
    nonisolated let pid: Int32
    nonisolated let runnerInstanceID: UUID
    nonisolated let ownershipID: UUID
    nonisolated let absoluteLifetimeDeadline: Double?
    nonisolated let registeredInteractive = true
    // Concrete wrapper only: Manager proof must use this exact authenticated client.
    nonisolated let client: AutomationRunnerClient
    private let registered: RegisteredRunnerChannel
    private let epoch: UUID
    private var finished = false
    init(client: AutomationRunnerClient, registered: RegisteredRunnerChannel, epoch: UUID) {
        self.client = client; self.registered = registered; self.epoch = epoch
        pid = client.pid; runnerInstanceID = client.runnerInstanceID; ownershipID = client.ownershipID
        absoluteLifetimeDeadline = client.absoluteLifetimeDeadline
    }
    func request(_ request: AutomationRequest, timeoutSeconds: Double) async throws -> AutomationReply {
        guard !finished else { throw AutomationError(code: .sessionExpired) }
        return try await client.request(request, timeoutSeconds: timeoutSeconds)
    }
    func closeAndWait(timeoutSeconds: Double) async throws -> ProcessExit? {
        guard !finished else { throw AutomationError(code: .sessionExpired) }
        finished = true
        await client.close()
        try await registered.confirmDrained(epoch: epoch, timeoutSeconds: min(timeoutSeconds, AutomationLimits.cleanupSeconds))
        return nil // No Runner termination is claimed.
    }
    func takeReleasedOwner(matching receipt: ControlReleaseReceipt) async throws -> OwnedRunnerProcess {
        guard !finished else { throw AutomationError(code: .sessionExpired) }
        finished = true
        let owner = try await client.takeValidatedReleasedOwner(matching: receipt)
        try await registered.confirmDrained(epoch: epoch)
        return owner
    }
}
#endif
