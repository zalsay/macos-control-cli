#!/usr/bin/env python3
"""Exercise production client request logic with a doubled transport boundary.

Startup/signature acquisition and the socket reader are composed by the fixture;
all request admission, timers, sending, correlation, and reply handling below
is compiled unchanged from AutomationRunnerClient.swift.
"""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '.build/request-interception-review-20261117/client-fixture'
OUT.mkdir(parents=True, exist_ok=True)
source = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'Sources/SafarierCore/AutomationRunnerClient.swift'
client = source.read_text()
header = client[client.index('public actor AutomationRunnerClient'):client.index('    private init(')]
timeout = client[client.index('    private static func validTimeout'):client.index('    static func prepareLocksDirectory')]
methods = client[client.index('    private func isReserved'):]
composition = '''
    private init(registered: Bool, validationDelay: Duration, sendDelay: Duration) {
        let transport = AutomationChannel(sendDelay: sendDelay), process = OwnedRunnerProcess()
        channel = transport; owner = RunnerControlPeer(child: process); pid = process.pid; ownershipID = process.ownershipID
        profileID = UUID(); runnerInstanceID = UUID(); absoluteLifetimeDeadline = nil
        fixtureContext = ControllerGenerationContext(channel: transport, registered: registered, validationDelay: validationDelay)
    }
    static func fixture(registered: Bool, validationDelay: Duration, sendDelay: Duration = .zero) -> AutomationRunnerClient {
        AutomationRunnerClient(registered: registered, validationDelay: validationDelay, sendDelay: sendDelay)
    }
    func fixtureReady(_ id: UUID) -> Bool { pending[id] != nil && ordinarySends == 0 && channel.hasSent(id) }
    func fixtureBytesSent(_ id: UUID) -> Bool { channel.hasSent(id) }
    func fixturePending(_ id: UUID) -> Bool { pending[id] != nil }
    func fixtureTarget() -> AutomationTargetIdentity { AutomationTargetIdentity(profileID: profileID, runnerInstanceID: runnerInstanceID, windowID: UUID(), pageID: UUID()) }
    func fixtureClosed() -> Bool { closed }
    func fixtureDeliver(_ reply: AutomationReply) async -> Bool { await receiveFrame(try! AutomationCodec.encode(reply)) }
'''
generated = OUT / 'Client.swift'
generated.write_text('import Foundation\nimport Darwin\nenum ControllerRequestMintUnavailable: Error { case noLongerLive }\n' + header + composition + timeout + methods)
fixture = ROOT / 'Tests/Fixtures/ControlReadRecovery'
env = os.environ.copy()
env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                *[str(ROOT / 'Sources/SafarierCore' / f) for f in ['SPIFeatures.swift', 'AutomationProtocol.swift']],
                str(generated), str(fixture / 'Support.swift'), str(fixture / 'Main.swift'),
                '-o', str(OUT / 'probe')], env=env, check=True, timeout=60)
for mode in ['timeout', 'cancel', 'validation-race', 'early-reply', 'release', 'unknown', 'wrong-kind', 'legacy', 'input']:
    subprocess.run([str(OUT / 'probe'), mode], check=True, timeout=10)
