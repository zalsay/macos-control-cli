#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/automation-stage9-worker-c"
mkdir -p "$OUT/modules" "$OUT/module-cache" "$OUT/clang-cache"
export CLANG_MODULE_CACHE_PATH="$OUT/clang-cache"
xcrun swiftc -swift-version 5 -enable-testing -module-cache-path "$OUT/module-cache" -emit-library -emit-module -module-name SafarierCore -emit-module-path "$OUT/modules/SafarierCore.swiftmodule" "$ROOT"/Sources/SafarierCore/*.swift -o "$OUT/modules/libSafarierCore.dylib"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$OUT/module-cache" -I "$OUT/modules" -L "$OUT/modules" -lSafarierCore -Xlinker -rpath -Xlinker "$OUT/modules" "$ROOT/scripts/automation-core-tests/Stage9WorkerCMain.swift" -o "$OUT/tests"
python3 -c 'import subprocess,sys; sys.exit(subprocess.run([sys.argv[1]],timeout=30).returncode)' "$OUT/tests"
