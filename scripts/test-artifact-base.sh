#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/automation-stage9-worker-b"
mkdir -p "$OUT/modules" "$OUT/module-cache" "$OUT/clang-cache"
export CLANG_MODULE_CACHE_PATH="$OUT/clang-cache"
xcrun swiftc -swift-version 5 -enable-testing -module-cache-path "$OUT/module-cache" -emit-library -emit-module -module-name SafarierCore -emit-module-path "$OUT/modules/SafarierCore.swiftmodule" "$ROOT"/Sources/SafarierCore/*.swift -o "$OUT/modules/libSafarierCore.dylib"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$OUT/module-cache" -I "$OUT/modules" -L "$OUT/modules" -lSafarierCore -Xlinker -rpath -Xlinker "$OUT/modules" "$ROOT/Tests/SafarierCoreTests/ArtifactBaseCases.swift" "$ROOT/scripts/automation-core-tests/ArtifactBaseMain.swift" -o "$OUT/artifact-tests"
FIXTURE="$(mktemp -d "$OUT/fixture.XXXXXXXX")"
trap 'rmdir "$FIXTURE"' EXIT
ARTIFACT_BASE_FIXTURE="$FIXTURE" python3 -c 'import subprocess,sys;r=subprocess.run([sys.argv[1]],timeout=30);sys.exit(r.returncode)' "$OUT/artifact-tests"
