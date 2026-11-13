import Foundation
import SafarierCore

public enum ManagerLaunchCases {
    struct Failure: Error { let label: String }
    static func check(_ value: Bool, _ label: String) throws { if !value { throw Failure(label: label) } }
    public static func run() throws -> Int {
        var n = 0
        var quiet = ManagerLaunchState()
        try check(quiet.handle(.interactiveWithoutActivation) == [], "quiet startup waits"); n += 1
        try check(quiet.handle(.interactive) == [], "open event waits"); n += 1
        try check(quiet.handle(.finishedLaunching) == [.showManagerWithoutActivation], "quiet startup shows without activation"); n += 1
        try check(quiet.handle(.openApplication) == [], "late startup open suppressed"); n += 1
        try check(quiet.handle(.interactive) == [.showManager], "subsequent human reopen activates"); n += 1
        try check(quiet.handle(.openApplication) == [.showManager], "later open activates"); n += 1
        var earlyQuiet = ManagerLaunchState()
        _ = earlyQuiet.handle(.interactiveWithoutActivation)
        try check(earlyQuiet.handle(.openApplication) == [], "early startup open suppressed"); n += 1
        try check(earlyQuiet.handle(.finishedLaunching) == [.showManagerWithoutActivation], "early open stays quiet"); n += 1
        try check(ManagerLaunchPolicy.decide(intent: .automation) == .stayAccessory, "automation"); n += 1
        try check(ManagerLaunchPolicy.decide(intent: .interactive) == .showManager, "interactive"); n += 1
        try check(ManagerLaunchPolicy.decide(intent: .undetermined) == .rejectUnverified, "unknown"); n += 1
        var state = ManagerLaunchState()
        try check(state.handle(.automation) == [], "automation before finish"); n += 1
        try check(state.handle(.finishedLaunching) == [], "finish after automation"); n += 1
        try check(state.handle(.interactive) == [.showManager], "interactive show"); n += 1
        try check(state.handle(.automation) == [], "automation leaves human window alone"); n += 1
        try check(state.handle(.windowClosed(pendingCommands: 1)) == [], "pending keeps process"); n += 1
        try check(state.handle(.interactive) == [.showManager], "reopen"); n += 1
        try check(state.handle(.windowClosed(pendingCommands: 0)) == [.terminate], "last window exits"); n += 1
        var quit = ManagerLaunchState(); try check(quit.handle(.quit) == [.cancelPending, .terminate], "quit cancels own"); n += 1
        var deferred = ManagerLaunchState()
        try check(deferred.handle(.quitRequested(pendingCommands: 2)) == [.cancelPending, .deferTermination], "pending quit defers"); n += 1
        try check(deferred.handle(.pendingCommandsChanged(1)) == [], "not yet drained"); n += 1
        try check(deferred.handle(.quitRequested(pendingCommands: 1)) == [.deferTermination], "repeat quit does not cancel twice"); n += 1
        try check(deferred.handle(.interactive) == [], "no show while terminating"); n += 1
        try check(deferred.handle(.pendingCommandsChanged(0)) == [.replyToTermination], "drained completes termination"); n += 1
        try check(deferred.handle(.pendingCommandsChanged(0)) == [], "termination reply once"); n += 1
        var closeDrain = ManagerLaunchState()
        _ = closeDrain.handle(.finishedLaunching); _ = closeDrain.handle(.interactive)
        try check(closeDrain.handle(.windowClosed(pendingCommands: 2)) == [], "window close with pending waits"); n += 1
        try check(closeDrain.handle(.automation) == [], "automation while draining no show"); n += 1
        try check(closeDrain.handle(.pendingCommandsChanged(1)) == [], "window pending still active"); n += 1
        try check(closeDrain.handle(.pendingCommandsChanged(0)) == [.terminate], "last window drained terminates"); n += 1
        try check(closeDrain.handle(.pendingCommandsChanged(0)) == [], "window drain terminates once"); n += 1
        var reopenDrain = ManagerLaunchState()
        _ = reopenDrain.handle(.finishedLaunching); _ = reopenDrain.handle(.interactive)
        _ = reopenDrain.handle(.windowClosed(pendingCommands: 1))
        try check(reopenDrain.handle(.interactive) == [.showManager], "human reopens while pending"); n += 1
        try check(reopenDrain.handle(.pendingCommandsChanged(0)) == [], "reopened window survives drain"); n += 1
        var closeThenQuit = ManagerLaunchState()
        _ = closeThenQuit.handle(.finishedLaunching); _ = closeThenQuit.handle(.interactive)
        _ = closeThenQuit.handle(.windowClosed(pendingCommands: 1))
        try check(closeThenQuit.handle(.quitRequested(pendingCommands: 1)) == [.cancelPending, .deferTermination], "quit supersedes window drain"); n += 1
        try check(closeThenQuit.handle(.pendingCommandsChanged(0)) == [.replyToTermination], "quit reply not premature terminate"); n += 1
        try check(closeThenQuit.handle(.pendingCommandsChanged(0)) == [], "superseded drain does not repeat"); n += 1
        var quitBeforeFinish = ManagerLaunchState()
        _ = quitBeforeFinish.handle(.interactive); _ = quitBeforeFinish.handle(.quitRequested(pendingCommands: 1))
        try check(quitBeforeFinish.handle(.finishedLaunching) == [], "termination prevents late startup show"); n += 1
        try check(quitBeforeFinish.handle(.windowClosed(pendingCommands: 0)) == [], "termination prevents window exit bypass"); n += 1
        try check(quitBeforeFinish.handle(.pendingCommandsChanged(0)) == [.replyToTermination], "termination reply after drain"); n += 1
        var immediate = ManagerLaunchState()
        try check(immediate.handle(.quitRequested(pendingCommands: 0)) == [.cancelPending, .terminate], "empty quit immediate"); n += 1
        try check(immediate.handle(.pendingCommandsChanged(0)) == [], "no unsolicited termination reply"); n += 1
        var bare = ManagerLaunchState(); try check(bare.handle(.interactive) == [], "interactive waits for finish"); n += 1
        try check(bare.handle(.finishedLaunching) == [.showManager], "interactive at finish"); n += 1
        var unknown = ManagerLaunchState(); try check(unknown.handle(.finishedLaunching) == [], "unknown no activation"); n += 1
        var mixed = ManagerLaunchState(); _ = mixed.handle(.interactive); _ = mixed.handle(.automation)
        try check(mixed.handle(.finishedLaunching).isEmpty, "automation dominates ambiguous startup"); n += 1
        try check(mixed.handle(.interactive) == [.showManager], "explicit reopen after automation"); n += 1
        let commands = ManagerMenuDefinition.commands
        for command in [ManagerMenuCommand.newProfile, .newSubscription, .launch, .edit, .duplicate, .refresh, .reload, .toggleSidebar, .cycle] { try check(commands.contains { $0.command == command }, "menu missing \(command)"); n += 1 }
        let shortcuts: [(ManagerMenuCommand, String, Bool, Bool)] = [(.newProfile, "n", false, false), (.newSubscription, "n", true, false), (.launch, "\r", false, false), (.edit, "e", false, false), (.duplicate, "d", false, false), (.reload, "r", false, false), (.toggleSidebar, "s", false, true), (.cycle, "`", false, false)]
        for (command, key, shift, control) in shortcuts {
            guard let entry = commands.first(where: { $0.command == command }) else { throw Failure(label: "missing shortcut") }
            try check(entry.key == key && entry.shift == shift && entry.control == control, "shortcut \(command)"); n += 1
        }
        let empty = ManagerMenuContext(hasSelectedProfile: false, selectedProfileStopped: false, hasSubscriptions: false)
        for command in [ManagerMenuCommand.launch, .edit, .duplicate, .refresh] { try check(!ManagerMenuDefinition.enabled(command, context: empty), "disabled \(command)"); n += 1 }
        let running = ManagerMenuContext(hasSelectedProfile: true, selectedProfileStopped: false, hasSubscriptions: true)
        try check(!ManagerMenuDefinition.enabled(.launch, context: running), "running launch disabled"); n += 1
        for command in [ManagerMenuCommand.edit, .duplicate, .refresh, .reload] { try check(ManagerMenuDefinition.enabled(command, context: running), "enabled \(command)"); n += 1 }
        let stopped = ManagerMenuContext(hasSelectedProfile: true, selectedProfileStopped: true, hasSubscriptions: true)
        try check(ManagerMenuDefinition.enabled(.launch, context: stopped), "stopped launch enabled"); n += 1
        return n
    }
}
