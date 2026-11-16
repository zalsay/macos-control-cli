#!/usr/bin/env python3
"""Exercise real signed-bundle validation and fixed-label timing diagnostics."""
import os
import importlib.util
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def run(command):
    return subprocess.run(command, check=True, capture_output=True, text=True, timeout=60)

with tempfile.TemporaryDirectory(prefix='.safarier-bundle-trace-', dir=Path.home()) as directory:
    work = Path(directory)
    app = work / 'fixture.app'
    macos = app / 'Contents/MacOS'
    macos.mkdir(parents=True)
    # HOME avoids the external volume's group-writable ancestor; ownership checks stay real.
    os.chmod(app, 0o700)
    source = work / 'fixture.c'
    source.write_text('int main(void) { return 0; }\n')
    run(['xcrun', 'clang', str(source), '-o', str(macos / 'fixture')])
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'sh.safarier.tracefixture', 'CFBundleExecutable': 'fixture',
        'CFBundlePackageType': 'APPL',
    }))
    run(['codesign', '--force', '--sign', '-', str(app)])
    executable = work / 'regression'
    spec = importlib.util.spec_from_file_location('candidate_build', ROOT / 'scripts/bound-control-candidate/build.py')
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    command, _ = builder.build_inputs(work, 'testing', 'release')
    c_flags = [command[i + 1] for i, argument in enumerate(command[:-1]) if argument == '-Xcc']
    run(['xcrun', 'clang', '-O2', '-Wno-deprecated-declarations', *c_flags,
         '-I', str(ROOT / 'Sources/BundleInventory/include'),
         '-I', str(ROOT / 'Sources/BinderIdentity/include'),
         str(ROOT / 'Tests/Fixtures/BundleRevalidationTrace/Main.c'),
         str(ROOT / 'Sources/BundleInventory/BundleInventory.c'),
         str(ROOT / 'Sources/BinderIdentity/BinderIdentity.c'),
         '-framework', 'Security', '-framework', 'CoreFoundation', '-lbsm', '-o', str(executable)])
    result = run([str(executable), str(app)])
    assert result.stdout.splitlines() == ['valid=0', 'wrong_identifier=1', 'expired=2', 'mutated=4'], result.stdout
    records = re.findall(r'^BUNDLE_CHECK_DIAG stage=(\w+) elapsed_us=\d+ remaining_us=\d+ result=(\d+)$', result.stderr, re.M)
    expected = [('inventoryBefore', '0'), ('plist', '0'), ('signature', '0'),
                ('mainPin', '0'), ('inventoryAfter', '0'),
                ('inventoryBefore', '0'), ('plist', '1'), ('inventoryBefore', '2'),
                ('inventoryBefore', '4')]
    assert records == expected, (records, result.stderr)
    assert str(app) not in result.stderr, 'diagnostics exposed a target path'
    print('PASS: signed validation, wrong identifier, expired deadline, changed contents, fixed stage timing and path redaction')
