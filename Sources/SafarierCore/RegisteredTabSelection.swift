import Foundation

/// A single generation can only lose authority; later snapshots cannot revive it.
public final class RegisteredTabSelection: @unchecked Sendable {
    public struct Group: Equatable, Sendable {
        public let id: UUID
        public let members: [UUID]
        public let selected: UUID?
        public let overviewVisible: Bool

        public init(id: UUID, members: [UUID], selected: UUID?, overviewVisible: Bool) {
            self.id = id; self.members = members; self.selected = selected; self.overviewVisible = overviewVisible
        }
    }

    public let generation = UUID()
    public let selectedWindow: UUID
    private let original: Group
    private let lock = NSLock()
    private var invalidated = false

    public init?(groups: [Group]) {
        guard groups.count == 1, let group = groups.first, !group.overviewVisible,
              !group.members.isEmpty, Set(group.members).count == group.members.count,
              let selected = group.selected, group.members.contains(selected) else { return nil }
        original = group
        selectedWindow = selected
    }

    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        invalidated = true
    }

    public func validate(groups: [Group]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if groups.count != 1 || groups.first != original { invalidated = true }
        return !invalidated
    }
}
