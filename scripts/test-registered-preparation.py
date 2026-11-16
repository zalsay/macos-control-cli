#!/usr/bin/env python3
"""Compile the real App slot against boundary doubles; no GUI or identity proof."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
fixture = root / 'Tests/Fixtures/RegisteredPreparation'
with tempfile.TemporaryDirectory(prefix='sf-registered-prepare-') as directory:
    out = Path(directory)
    subprocess.run([
        'xcrun', 'swiftc', '-swift-version', '5', '-emit-module', '-emit-library',
        '-module-name', 'SafarierCore', str(fixture / 'Core.swift'),
        '-o', str(out / 'libSafarierCore.dylib'),
        '-emit-module-path', str(out / 'SafarierCore.swiftmodule'),
    ], check=True, timeout=60)
    subprocess.run([
        'xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
        '-D', 'SAFARIER_BOUND_LOCAL_CANDIDATE', '-D', 'SAFARIER_INTERNAL_TEST_APP',
        '-I', directory, '-L', directory, '-lSafarierCore', '-Xlinker', '-rpath', '-Xlinker', directory,
        str(root / 'Sources/Safarier/Automation/BoundRunnerServiceSlot.swift'),
        str(root / 'Sources/Safarier/Automation/RegisteredPrepareTrace.swift'),
        str(fixture / 'App.swift'), str(fixture / 'Main.swift'), '-o', str(out / 'regression'),
    ], check=True, timeout=60)
    subprocess.run([str(out / 'regression')], check=True, timeout=10)
