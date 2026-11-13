#!/usr/bin/env python3
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[2]
factory = (root / 'Sources/SafarierWebKit/WebViewConfigurationFactory.swift').read_text()
plan = (root / 'Sources/SafarierCore/RunnerPreparationPlan.swift').read_text()
make = factory.split('public func make(', 1)[1]
helper = factory.split('static func proxyPassword(', 1)[-1].split('public func make(', 1)[0]
background = helper.split('case .automationBackground:', 1)[-1]
checks = {
    'factory hard gate is first operation': 'try Self.requireExecutionPolicy(executionPolicy)' in make and make.index('try Self.requireExecutionPolicy(executionPolicy)') < make.index('WKWebViewConfiguration()'),
    'make reuses password dispatch once': make.count('Self.proxyPassword(') == 1 and 'credentials.password(forKey:' not in make and 'credentials.passwordWithoutInteraction(forKey:' not in make,
    'noninteractive dispatch exists': 'static func proxyPassword(' in factory and 'passwordWithoutInteraction(forKey:' in factory,
    'background empty username guard precedes safe read': 'guard proxy.username?.isEmpty == false else { return nil }' in background and background.index('guard proxy.username?.isEmpty == false else { return nil }') < background.index('passwordWithoutInteraction(forKey:'),
    'metadata plan does not reject usernames': 'proxy.username' not in plan,
    'background binding verified and geo denied': all(s in plan for s in ['bound.subscription.id == subscriptionID', 'bound.node.name == name', 'bound.subscription.nodes.first(where: { $0.name == name }) == bound.node', 'boundNodeMismatch', '!profile.followProxyLanguages', '!profile.followProxyTimeZone', '.backendUnavailable']),
}
for label, ok in checks.items(): print(('PASS ' if ok else 'FAIL ') + label)
sys.exit(0 if all(checks.values()) else 1)
