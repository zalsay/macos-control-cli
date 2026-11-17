#!/usr/bin/env python3
"""Check retained Manager routing when a bundle ID also names a CLI daemon."""
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='.safarier-manager-address-', dir=Path.home()) as directory:
    executable = Path(directory) / 'fixture'
    subprocess.run([
        'xcrun', 'clang', '-O1', '-fblocks', '-Wno-deprecated-declarations',
        '-DAEDeterminePermissionToAutomateTarget=fixture_permission', '-DAESendMessage=fixture_send',
        '-DAEGetAttributePtr=fixture_get_attribute',
        '-I', str(ROOT / 'Sources/SafarierControlSupport/include'),
        '-I', str(ROOT / 'Sources/BinderIdentity/include'),
        str(ROOT / 'Tests/Fixtures/ControlManagerAddress/Main.c'),
        str(ROOT / 'Sources/SafarierControlSupport/ControlSupport.c'),
        str(ROOT / 'Sources/SafarierControlSupport/ControlAuthorization.c'),
        str(ROOT / 'Sources/BinderIdentity/BinderIdentity.c'),
        '-framework', 'Security', '-framework', 'CoreFoundation', '-framework', 'Carbon', '-lbsm',
        '-o', str(executable),
    ], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(executable)], check=True, capture_output=True)
    failed = False
    for scenario in ('send', 'authorize', 'authorize-request', 'deny-send', 'timeout-send', 'deny-query', 'timeout-query', 'changed-manager', 'changed-serial'):
        result = subprocess.run([str(executable), scenario], capture_output=True, text=True, timeout=20)
        print(result.stdout.strip(), flush=True)
        if result.returncode:
            print(f'{scenario}: exit {result.returncode}; {result.stderr}', flush=True)
            failed = True
    raise SystemExit(1 if failed else 0)
