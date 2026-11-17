#!/usr/bin/env python3
"""Exercise BundleInventory's ancestor mapping under deterministic mutations."""
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix='.safarier-inventory-race-', dir=Path.home()) as directory:
    work = Path(directory)
    original = (ROOT / 'Sources/BundleInventory/BundleInventory.c').read_text()
    anchor = ' if(!good_dir(&st[n]))goto done;\n for(size_t i=0;i<=n;i++)'
    assert original.count(anchor) == 1
    instrumented = original.replace(anchor, ' if(!good_dir(&st[n]))goto done;\n extern void bb_test_open_root_checkpoint(void); bb_test_open_root_checkpoint();\n for(size_t i=0;i<=n;i++)')
    source = work / 'instrumented.c'
    source.write_text(instrumented)
    executable = work / 'fixture'
    subprocess.run(['xcrun', 'clang', '-O2', '-Wno-deprecated-declarations',
                    '-I', str(ROOT / 'Sources/BundleInventory/include'),
                    '-I', str(ROOT / 'Sources/BinderIdentity/include'),
                    str(ROOT / 'Tests/Fixtures/BundleAncestorRace/Main.c'), str(source),
                    str(ROOT / 'Sources/BinderIdentity/BinderIdentity.c'),
                    '-framework', 'Security', '-framework', 'CoreFoundation', '-lbsm', '-o', str(executable)], check=True)
    for scenario in ('sibling', 'permissions', 'acl', 'replacement', 'root'):
        ancestor = work / scenario / 'ancestor'
        app = ancestor / 'fixture.app'
        app.mkdir(parents=True, mode=0o700)
        result = subprocess.run([str(executable), scenario, str(ancestor), str(app)], capture_output=True, text=True)
        print(result.stdout.strip(), flush=True)
        if result.returncode:
            raise SystemExit(f'{scenario}: exit {result.returncode}; {result.stderr}')
