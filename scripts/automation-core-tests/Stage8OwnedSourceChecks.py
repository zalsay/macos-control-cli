from pathlib import Path
s = (Path(__file__).resolve().parents[2] / 'Sources/Safarier/Automation/OwnedBrowserAutomationPage.swift').read_text()
attach = s.split('static func attach(', 1)[1].split('private func checkedObjects()', 1)[0]
assert attach.index('requireShippingAdmission()') < attach.index('NativePageInput.open(') < attach.index('OwnedBrowserAutomationPage(session:')
for check in ('automationBackground', 'openControllers.contains', 'controller.session === session', 'onAutomationNavigation == nil', 'onAutomationUIBlocked == nil', '!controller.isShowingStartPage', '!NSApp.isActive', '!controller.window.isKeyWindow', '!controller.window.isMainWindow'):
    assert check in attach, check
nav = s.split('private func navigate(', 1)[1].split('private func handleNavigation(', 1)[0]
for check in ('version + 1', 'input?.closeActivity()', 'webView.load(URLRequest(url: url))', 'correlation.begin(navigation)', 'correlation.finish(navigation', 'navigationOutcome', 'waitUntilReady()', 'Task.isCancelled', 'deadline'):
    assert check in nav, check
assert 'makeFirstResponder' not in s and 'loadHTMLString' not in s and 'terminatedOwnedRunner' not in s
cleanup = s.split('func destroy() async -> Bool', 1)[1]
for check in ('correlation.invalidate()', 'input?.closeActivity()', 'window.close()', 'return false'):
    assert check in cleanup, check
for forbidden in ('.release(', '.click(', '.mouseUp(', '.drag('):
    assert forbidden not in cleanup, forbidden
print('stage8 owned source checks: PASS')
assert nav.index('oldInput.closeActivity()') < nav.index('oldInput.requiresOwnedTargetDestruction') < nav.index('await oldInput.waitUntilClosed()') < nav.index('webView.load(URLRequest(url: url))') < nav.index('NativePageInput.open(')
assert 'oldInput.activityStatus == .OK' in nav
perform = s.split('func perform(_ action:', 1)[1].split('private func navigate(', 1)[0]
assert perform.count('!Task.isCancelled') >= 2
print('stage8 owned retirement checks: PASS')
assert nav.index('let deadline = ContinuousClock.now') < nav.index('oldInput.closeActivity()')
assert nav.count('ContinuousClock.now < deadline') >= 4
assert nav.rfind('ContinuousClock.now < deadline', 0, nav.index('webView.load(URLRequest(url: url))')) > nav.index('await oldInput.waitUntilClosed()')
assert nav.rfind('ContinuousClock.now < deadline', 0, nav.index('NativePageInput.open(')) > nav.index('correlation.finish(navigation')
assert nav.rfind('ContinuousClock.now < deadline', 0, nav.index('return .navigationFinished')) > nav.index('await newInput.waitUntilReady()')
print('stage8 navigation deadline checks: PASS')
