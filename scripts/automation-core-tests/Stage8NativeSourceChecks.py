from pathlib import Path
p = Path(__file__).resolve().parents[2] / 'Sources/Safarier/Automation/NativePageInput.swift'
s = p.read_text()
assert 'viewVersion: UInt64 = 1' in s
assert 'private func beginActivity()' in s
assert s.count('SFRBeginBackgroundPageActivity(') == 1
body = s.split('static func open(webView:', 1)[1].split('private init(', 1)[0]
assert body.index('requireShippingAdmission()') < body.index('NativePageInput(webView:') < body.index('beginActivity()')
assert 'func waitUntilReady() async throws' in s
print('stage8 native source checks: PASS')
close = s.split('func closeActivity()', 1)[1]
assert 'finishRequested' in close
assert close.index('guard !finishRequested') < close.index('SFRFinishBackgroundPageActivity')
assert 'func waitUntilClosed() async throws' in s
assert 'activityStatus == .OK' in s.split('func waitUntilClosed()', 1)[1].split('private func valid(', 1)[0]
print('stage8 native retirement checks: PASS')
assert close.count('activityClosed = true') == 2
assert 'guard let token = activityLease else { activityClosed = true; return }' in close
assert 'self?.activityClosed = true' in close
wait = s.split('func waitUntilClosed()', 1)[1].split('private func valid(', 1)[0]
assert 'activityClosed = true' not in wait and 'Task.isCancelled' in wait and 'deadline' in wait
print('stage8 finish acknowledgement checks: PASS')
