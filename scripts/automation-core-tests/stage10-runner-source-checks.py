#!/usr/bin/env python3
from pathlib import Path
import sys
import re
root = Path(__file__).resolve().parents[2]
def read(path):
    p = root / path
    return p.read_text() if p.exists() else ''
main = read('Sources/Safarier/RunnerMain.swift')
prep = read('Sources/Safarier/RunnerPreparation.swift')
factory = read('Sources/SafarierWebKit/WebViewConfigurationFactory.swift')
legacy = read('Sources/Safarier/Automation/RunnerAutomationService.swift').split('enum RunnerAutomationEntry', 1)[-1]
entry = prep.split('extension RunnerAutomationEntry', 1)[-1]
def check(ok, msg):
    print(('PASS' if ok else 'FAIL') + ' ' + msg)
    return bool(ok)
checks = []
checks.append(check('RunnerPreparation.prepare(' in main and 'RunnerPreparation.prepareBackground(' in entry and prep.count('try finish(') == 2, 'interactive and background use shared finish'))
checks.append(check('RunnerPreparationPlan.resolve(' in prep, 'shared preparation uses core selector'))
body = prep.split('static func prepare(', 1)[-1]
checks.append(check('try WebViewConfigurationFactory.requireExecutionPolicy(executionPolicy)' in body and body.index('try WebViewConfigurationFactory.requireExecutionPolicy(executionPolicy)') < body.find('RunnerPreparationPlan.resolve('), 'factory policy is first preparation gate'))
checks.append(check('static func requireExecutionPolicy(' in factory and 'try Self.requireExecutionPolicy(executionPolicy)' in factory.split('public func make(', 1)[-1], 'factory retains shared hard gate'))
background = main.split('if spec.backgroundAutomation {', 1)[-1].split('installTerminationCleanup()', 1)[0]
checks.append(check('validateConnectedStream' in background and 'AutomationChannel(adopting:' not in background, 'validate fd0 without adopting before preparation'))
checks.append(check('NativeInputPreflight.shippingAdmissionAvailable' in entry and 'AutomationRunnerBootstrap.serveUnavailable' in entry and 'AutomationRunnerBootstrap.serveUnavailable' in legacy, 'native admission and legacy unavailable retained'))
checks.append(check('makeAutomationService(' in entry and '.serve(channel:' in entry, 'future success uses existing service'))
checks.append(check('RunnerPreparation' not in legacy and 'BrowserSession' not in legacy and 'AppKit' not in legacy, 'legacy service stays standalone'))
checks.append(check(entry.find('shippingAdmissionAvailable') < entry.find('RunnerPreparation.prepareBackground(') < entry.find('RunnerMain.makeAutomationService(') < entry.find('await service.serve(channel:'), 'native gate and preparation precede service'))
checks.append(check(entry.find('RunnerPreparation.prepareBackground(') < entry.find('AutomationChannel(adopting: rawInput)', entry.find('RunnerPreparation.prepareBackground(')), 'success path adopts only after preparation'))
checks.append(check('RunnerMain.startProxyCore(' in prep and 'RunnerMain.resolveFollowProxy(' in prep and 'RunnerMain.relaunch(' in prep and 'RunnerPreparationPlan.resolve(' not in main, 'reuse original subscription and geo implementation'))
checks.append(check('NSApplication.shared' not in prep and 'NSApplication.shared' not in entry, 'preparation and entry do not create NSApplication'))
# Regression checks for the shipping boundary, ordered before any side effects.
startup_guard = re.search(r'guard\s+profile\.allowsBackgroundAutomation\s*,\s*spec\.startURL\s*==\s*URL\(string:\s*"about:blank"\)\s*,\s*spec\.spiOverride\s*==\s*nil\s*,\s*!spec\.probe\s+else', background)
checks.append(check(bool(startup_guard) and startup_guard.start() < background.find('validateConnectedStream'), 'background startup authorization precedes fd validation'))
service_body = main.split('static func makeAutomationService(', 1)[-1].split('/// 跟随代理', 1)[0]
service_gate = re.search(r'\) throws -> RunnerAutomationService\s*\{\s*try NativePageInput\.requireShippingAdmission\(\)\s*guard\s+prepared\.output\.executionPolicy\s*==\s*\.automationBackground\s*,\s*prepared\.effectiveProfile\.allowsBackgroundAutomation\s+else', service_body)
checks.append(check(bool(service_gate) and service_gate.end() < service_body.find('NSApplication.shared'), 'service independently checks admission and prepared policy before NSApplication'))
policy_gate = re.search(r'try WebViewConfigurationFactory\.requireExecutionPolicy\(executionPolicy\)\s*guard\s+executionPolicy\s*!=\s*\.automationBackground\s*,\s*!spec\.backgroundAutomation\s+else\s*\{\s*throw RunnerPreparationError\.invalidBackgroundLaunch\s*\}', body)
checks.append(check(bool(policy_gate) and policy_gate.end() < body.find('RunnerPreparationPlan.resolve('), 'sync path independently rejects background before workspace readers'))
sys.exit(0 if all(checks) else 1)
