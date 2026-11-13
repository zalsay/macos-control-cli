#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/automation-snapshot"
mkdir -p "$OUT/modules" "$OUT/module-cache" "$OUT/clang-cache"
export CLANG_MODULE_CACHE_PATH="$OUT/clang-cache"
xcrun swiftc -swift-version 5 -enable-testing -module-cache-path "$OUT/module-cache" -emit-library -emit-module -module-name SafarierCore -emit-module-path "$OUT/modules/SafarierCore.swiftmodule" "$ROOT"/Sources/SafarierCore/*.swift -o "$OUT/modules/libSafarierCore.dylib"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$OUT/module-cache" -I "$OUT/modules" -L "$OUT/modules" -lSafarierCore -Xlinker -rpath -Xlinker "$OUT/modules" "$ROOT/Tests/SafarierCoreTests/AutomationSnapshotCases.swift" "$ROOT/scripts/automation-core-tests/SnapshotMain.swift" -o "$OUT/snapshot-tests"
FIXTURE="$(mktemp -d "$OUT/fixture.XXXXXXXX")"
trap 'rmdir "$FIXTURE"' EXIT
python3 -c 'import subprocess,sys; r=subprocess.run([sys.argv[1],sys.argv[2]],timeout=30); sys.exit(r.returncode)' "$OUT/snapshot-tests" "$FIXTURE"
