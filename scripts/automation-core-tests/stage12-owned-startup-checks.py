#!/usr/bin/env python3
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[2]
s = (root / 'Sources/Safarier/RunnerPreparation.swift').read_text()
prep = s.split('static func prepare(', 1)[-1].split('static func prepareBackground(', 1)[0]
background = s.split('static func prepareBackground(', 1)[-1].split('private static func installDisplay(', 1)[0]
entry = s.split('extension RunnerAutomationEntry', 1)[-1]
finish = s.split('private static func finish(', 1)[-1].split('// Keep the Foundation-only', 1)[0]
watcher = s.split('final class BackgroundStartupControlWatch', 1)[-1].split('// Bridges disconnects', 1)[0]
resources = s.split('final class OwnedResources', 1)[-1].split('static func prepareBackground(', 1)[0]
checks = {
    'background cancellation follows factory gate': 'try WebViewConfigurationFactory.requireExecutionPolicy(.automationBackground)\n        try Task.checkCancellation()' in background,
    'watch validates before duplicating': 0 <= watcher.find('AutomationChannel.validateConnectedStream(fileDescriptor: input.fileDescriptor)') < watcher.find('F_DUPFD_CLOEXEC'),
    'EINTR honors stop': 'if result < 0 && errno == EINTR {\n                    if state.isStopping() { return false }' in watcher,
    'finish independently rejects background geo': 'executionPolicy == .automationBackground' in finish and '!profile.followProxyLanguages' in finish and '!profile.followProxyTimeZone' in finish and finish.find('throw AutomationError(code: .backendUnavailable)') < finish.find('RunnerMain.resolveFollowProxy('),
    'sync rejects background': 'executionPolicy != .automationBackground' in prep and '!spec.backgroundAutomation' in prep,
    'background factory and native precede plan': 0 <= background.find('requireExecutionPolicy(.automationBackground)') < background.find('requireShippingAdmission()') < background.find('RunnerPreparationPlan.resolve('),
    'owned start only': 'startOwned(' in background and 'RunnerMain.startProxyCore(' not in background,
    'shared finish': 'finish(' in prep and 'finish(' in background,
    'explicit close before return': 'await resources.close()' in entry and 'result.prepared' in entry,
    'cleanup uses observed exit': 'stopOwned(identity, timeoutSeconds: remaining)' in resources and '!= nil' in resources,
    'absolute deadline and stop request before task': 0 <= resources.find('let (deadline, overflow) =') < resources.find('requestStopOwned(identity)') < resources.find('Task.detached'),
    'remaining bounded and late result rejected': 'deadline - now' in resources and 'DispatchTime.now().uptimeNanoseconds <= deadline' in resources,
    'close is single flight': 'if let closeTask { return await closeTask.value }' in s and 'closeTask = task' in s,
    'no deinit resource cleanup dependency': 'deinit' not in s.split('final class OwnedResources', 1)[-1].split('static func prepareBackground(', 1)[0],
    'failed spawn closes pending owners': 'await manager.stopAllOwned(timeoutSeconds: 2)' in background and 'manager.pendingOwnedCount == 0' in background,
    'prepare failure observes close': 'guard await resources.close() else { throw BackgroundError.ownedCleanupUnobserved }' in background,
    'service failure closes and returns nonzero': '_ = await resources.close()' in entry and 'return 1' in entry,
    'unobserved cleanup returns nonzero': 'return await resources.close() ? status : 1' in entry and 'catch RunnerPreparation.BackgroundError.ownedCleanupUnobserved' in entry,
    'cancellation checked after launch': background.find('startOwned(') < background.rfind('try Task.checkCancellation()') < background.find('return BackgroundResult('),
    'legacy start remains only sync': 'RunnerMain.startProxyCore(' in prep and 'RunnerMain.startProxyCore(' not in background,
    'shared device setup': prep.count('installDisplay(') == 1 and background.count('installDisplay(') == 1,
    'watcher after gates before service': 0 <= entry.find('requireExecutionPolicy(.automationBackground)') < entry.find('requireShippingAdmission()') < entry.find('BackgroundStartupControlWatch(input: rawInput') < entry.find('await watch.stop()') < entry.find('RunnerMain.makeAutomationService('),
    'watcher no read or shutdown': all(x not in s.split('final class BackgroundStartupControlWatch', 1)[-1].split('// Keep the Foundation-only', 1)[0] for x in ['Darwin.read(', 'shutdown(', 'recv(']),
    'initial poll before creating preparation task': entry.find('await watch.waitUntilReady()') < entry.find('let preparation = Task') < entry.find('cancellation.install { preparation.cancel() }'),
    'disconnect cancellation is lock coordinated': 'final class BackgroundStartupCancellation' in s and 'if disconnected { cancel() }' in s,
    'watch polls bounded without consuming input': all(x in s for x in ['F_DUPFD_CLOEXEC', 'Int16(POLLIN)', 'POLLHUP | POLLERR | POLLNVAL', 'stopping || firstPoll ? 0 : 25', 'defer { state.markReady(); Darwin.close(fd) }']),
    'no manufactured receipt': 'CleanupReceipt' not in s,
}
for label, ok in checks.items(): print(('PASS ' if ok else 'FAIL ') + label)
sys.exit(not all(checks.values()))
