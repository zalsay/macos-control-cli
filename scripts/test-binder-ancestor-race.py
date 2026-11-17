#!/usr/bin/env python3
"""Exercise file snapshot ancestor identity under deterministic mutations."""
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='.safarier-binder-race-', dir=Path.home()) as directory:
    work = Path(directory)
    original = (ROOT / 'Sources/BinderIdentity/BinderIdentity.c').read_text()
    anchor = '    if (callback) { err=callback(path,deadline,context);'
    assert original.count(anchor) == 1
    source = work / 'instrumented.c'
    source.write_text(original.replace(anchor, '    extern void bi_test_snapshot_checkpoint(void); bi_test_snapshot_checkpoint();\n' + anchor))
    executable = work / 'fixture'
    subprocess.run(['xcrun', 'clang', '-O2', '-Wno-deprecated-declarations',
                    '-I', str(ROOT / 'Sources/BinderIdentity/include'),
                    str(ROOT / 'Tests/Fixtures/BundleAncestorRace/Binder.c'), str(source),
                    '-framework', 'Security', '-framework', 'CoreFoundation', '-lbsm', '-o', str(executable)], check=True)
    for scenario in ('sibling', 'permissions', 'acl', 'replacement', 'file'):
        ancestor = work / scenario / 'ancestor'
        ancestor.mkdir(parents=True, mode=0o700)
        file = ancestor / 'object'
        file.write_text('unchanged')
        result = subprocess.run([str(executable), scenario, str(ancestor), str(file)], capture_output=True, text=True)
        print(result.stdout.strip(), flush=True)
        if result.returncode:
            raise SystemExit(f'{scenario}: exit {result.returncode}; {result.stderr}')
