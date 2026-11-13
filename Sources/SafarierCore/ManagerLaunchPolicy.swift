import Foundation

public enum ManagerLaunchIntent: Sendable { case automation, interactive, undetermined }
public enum ManagerLaunchDecision: Sendable { case stayAccessory, showManager, rejectUnverified }
public enum ManagerLaunchPolicy {
    public static func decide(intent: ManagerLaunchIntent) -> ManagerLaunchDecision {
        switch intent { case .automation: return .stayAccessory; case .interactive: return .showManager; case .undetermined: return .rejectUnverified }
    }
}
public enum ManagerLaunchEvent: Sendable {
    case automation, interactive, interactiveWithoutActivation, openApplication, finishedLaunching, windowClosed(pendingCommands: Int), quit
    case quitRequested(pendingCommands: Int), pendingCommandsChanged(Int)
}
public enum ManagerLaunchEffect: Equatable, Sendable { case showManager, showManagerWithoutActivation, terminate, cancelPending, deferTermination, replyToTermination }
/// Pure lifecycle reducer: a visible human window is never hidden by automation.
public struct ManagerLaunchState: Sendable {
    private var finished = false
    private var automationBeforeFinish = false
    private var interactiveBeforeFinish = false
    private var quietBeforeFinish = false
    private var suppressStartupOpen = false
    private var humanWindow = false
    private var terminating = false
    private var awaitingTerminationReply = false
    private var awaitingWindowDrain = false
    public init() {}
    public mutating func handle(_ event: ManagerLaunchEvent) -> [ManagerLaunchEffect] {
        switch event {
        case .automation:
            if !finished { automationBeforeFinish = true }
            return []
        case .interactive:
            guard !terminating else { return [] }
            guard finished else { interactiveBeforeFinish = true; return [] }
            awaitingWindowDrain = false
            humanWindow = true; return [.showManager]
        case .interactiveWithoutActivation:
            guard !finished, !terminating else { return [] }
            quietBeforeFinish = true
            suppressStartupOpen = true
            return []
        case .openApplication:
            if suppressStartupOpen { suppressStartupOpen = false; return [] }
            return handle(.interactive)
        case .finishedLaunching:
            guard !finished, !terminating else { return [] }
            finished = true
            if quietBeforeFinish { humanWindow = true; return [.showManagerWithoutActivation] }
            if interactiveBeforeFinish && !automationBeforeFinish { humanWindow = true; return [.showManager] }
            return []
        case .windowClosed(let pending):
            guard humanWindow, !terminating else { return [] }
            humanWindow = false
            if pending > 0 { awaitingWindowDrain = true; return [] }
            return [.terminate]
        case .quit:
            return handle(.quitRequested(pendingCommands: 0))
        case .quitRequested(let pending):
            if awaitingTerminationReply { return [.deferTermination] }
            guard !terminating else { return [] }
            terminating = true
            awaitingWindowDrain = false
            if pending > 0 { awaitingTerminationReply = true; return [.cancelPending, .deferTermination] }
            return [.cancelPending, .terminate]
        case .pendingCommandsChanged(let pending):
            guard pending == 0 else { return [] }
            if awaitingTerminationReply {
                awaitingTerminationReply = false
                return [.replyToTermination]
            }
            if awaitingWindowDrain && !terminating && !humanWindow {
                awaitingWindowDrain = false
                return [.terminate]
            }
            return []
        }
    }
}

public enum ManagerMenuCommand: String, Sendable { case newProfile, newSubscription, launch, edit, duplicate, refresh, reload, toggleSidebar, cycle }
public struct ManagerMenuEntry: Sendable {
    public let command: ManagerMenuCommand, title: String, key: String, shift: Bool, control: Bool
    public init(_ command: ManagerMenuCommand, _ title: String, _ key: String = "", shift: Bool = false, control: Bool = false) { self.command = command; self.title = title; self.key = key; self.shift = shift; self.control = control }
}
public struct ManagerMenuContext: Sendable {
    public let hasSelectedProfile: Bool, selectedProfileStopped: Bool, hasSubscriptions: Bool
    public init(hasSelectedProfile: Bool, selectedProfileStopped: Bool, hasSubscriptions: Bool) { self.hasSelectedProfile = hasSelectedProfile; self.selectedProfileStopped = selectedProfileStopped; self.hasSubscriptions = hasSubscriptions }
}
public enum ManagerMenuDefinition {
    public static let commands: [ManagerMenuEntry] = [
        .init(.newProfile, "新建环境…", "n"), .init(.newSubscription, "添加订阅…", "n", shift: true),
        .init(.launch, "启动浏览器", "\r"), .init(.edit, "编辑…", "e"), .init(.duplicate, "复制环境", "d"),
        .init(.refresh, "刷新全部订阅"), .init(.reload, "重新读取数据", "r"),
        .init(.toggleSidebar, "显示或隐藏边栏", "s", control: true), .init(.cycle, "循环显示浏览器窗口", "`")
    ]
    public static func enabled(_ command: ManagerMenuCommand, context: ManagerMenuContext) -> Bool {
        switch command {
        case .launch: return context.hasSelectedProfile && context.selectedProfileStopped
        case .edit, .duplicate: return context.hasSelectedProfile
        case .refresh: return context.hasSubscriptions
        default: return true
        }
    }
}
