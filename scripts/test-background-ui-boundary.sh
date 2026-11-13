#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/background-ui-boundary"
mkdir -p "$OUT/modules" "$OUT/module-cache" "$OUT/clang-cache"
export CLANG_MODULE_CACHE_PATH="$OUT/clang-cache"
python3 - "$ROOT" "$OUT" <<'PY'
import os, subprocess, sys
root, out = sys.argv[1:]
def run(args, timeout):
    subprocess.run(args, check=True, timeout=timeout)
common = ['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', out + '/module-cache']
run(common + ['-emit-library', '-emit-module', '-module-name', 'SafarierCore', '-emit-module-path', out + '/modules/SafarierCore.swiftmodule', root + '/Sources/SafarierCore/BackgroundPagePolicy.swift', '-o', out + '/modules/libSafarierCore.dylib'], 30)
run(common + ['-parse-as-library', '-I', out + '/modules', '-L', out + '/modules', '-lSafarierCore', '-Xlinker', '-rpath', '-Xlinker', out + '/modules', root + '/Tests/SafarierCoreTests/BackgroundUIBoundaryCases.swift', root + '/scripts/automation-core-tests/BackgroundBoundaryMain.swift', '-o', out + '/background-policy-tests'], 30)
run([out + '/background-policy-tests'], 10)
PY
