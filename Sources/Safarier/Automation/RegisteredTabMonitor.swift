#if SAFARIER_BOUND_LOCAL_CANDIDATE
import AppKit
import SafarierCore

/// Observes only a group supplied by the already-owned BrowserSession.
@MainActor final class RegisteredTabMonitor {
    private final class Lifecycle: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        private var notified = false
        func stop() { lock.lock(); active = false; lock.unlock() }
        func isActive() -> Bool { lock.lock(); defer { lock.unlock() }; return active }
        func claimNotification() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard active, !notified else { return false }
            notified = true
            return true
        }
    }
    private let group: NSWindowTabGroup
    private let windows: [(NSWindow, UUID)]
    private let groupID: UUID
    private let state: RegisteredTabSelection
    private let lifecycle = Lifecycle()
    private var observations: [NSKeyValueObservation] = []
    private var changeHandler: (() -> Void)?
    var selectedID: UUID { state.selectedWindow }

    init?(group: NSWindowTabGroup, windows: [(NSWindow, UUID)], onRevoke: @escaping @Sendable () -> Void = {}, onInvalidated: @escaping @MainActor () -> Void) {
        let groupID = UUID()
        guard let initial = Self.snapshot(group: group, windows: windows, groupID: groupID),
              let state = RegisteredTabSelection(groups: [initial]) else { return nil }
        self.group = group; self.windows = windows; self.groupID = groupID; self.state = state
        // Invalidate synchronously before scheduling cleanup, even when the
        // notification comes from outside the main actor.
        let lifecycle = self.lifecycle
        let changed: (String) -> Void = { reason in
            state.invalidate()
            guard lifecycle.claimNotification() else { return }
            onRevoke()
            fputs("TAB_MONITOR_DIAG phase=revoked reason=\(reason) monotonic_ms=\(DispatchTime.now().uptimeNanoseconds / 1_000_000)\n", stderr)
            Task { @MainActor in
                guard lifecycle.isActive() else { return }
                onInvalidated()
            }
        }
        changeHandler = { changed("explicit") }
        observations = [
            group.observe(\.selectedWindow, options: [.new]) { _, _ in changed("selection") },
            group.observe(\.windows, options: [.new]) { _, _ in changed("membership") },
            group.observe(\.isOverviewVisible, options: [.new]) { _, _ in changed("overview") }
        ]
        guard isValid() else { stop(); return nil }
    }

    deinit { lifecycle.stop() }

    func stop() {
        lifecycle.stop()
        state.invalidate()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        changeHandler = nil
        fputs("TAB_MONITOR_DIAG phase=stop monotonic_ms=\(DispatchTime.now().uptimeNanoseconds / 1_000_000)\n", stderr)
    }

    func invalidate() { changeHandler?() }

    func isValid() -> Bool {
        guard let snapshot = Self.snapshot(group: group, windows: windows, groupID: groupID) else {
            invalidate(); return false
        }
        guard state.validate(groups: [snapshot]) else { invalidate(); return false }
        return true
    }

    func matches(windows current: [(NSWindow, UUID)]) -> Bool {
        let matches = current.count == windows.count && windows.allSatisfy { original in current.contains { $0.0 === original.0 && $0.1 == original.1 } }
        if !matches { invalidate() }
        return matches
    }

    private static func snapshot(group: NSWindowTabGroup, windows: [(NSWindow, UUID)], groupID: UUID) -> RegisteredTabSelection.Group? {
        guard !windows.isEmpty, Set(windows.map { ObjectIdentifier($0.0) }).count == windows.count,
              Set(windows.map(\.1)).count == windows.count,
              group.windows.count == windows.count else { return nil }
        var members: [UUID] = []
        for window in group.windows {
            guard window.tabGroup === group, let match = windows.first(where: { $0.0 === window }) else { return nil }
            members.append(match.1)
        }
        let selected = group.selectedWindow.flatMap { selected in windows.first { $0.0 === selected }?.1 }
        return .init(id: groupID, members: members, selected: selected, overviewVisible: group.isOverviewVisible)
    }
}
#endif
