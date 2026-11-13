#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/automation-stage8-worker-b"
mkdir -p "$OUT/modules" "$OUT/module-cache" "$OUT/clang-cache"
export CLANG_MODULE_CACHE_PATH="$OUT/clang-cache"
xcrun swiftc -swift-version 5 -enable-testing -module-cache-path "$OUT/module-cache" -emit-library -emit-module -module-name SafarierCore -emit-module-path "$OUT/modules/SafarierCore.swiftmodule" "$ROOT"/Sources/SafarierCore/*.swift -o "$OUT/modules/libSafarierCore.dylib"
xcrun swiftc -swift-version 5 -D RUNNER_SERVICE_STANDALONE -parse-as-library -module-cache-path "$OUT/module-cache" -I "$OUT/modules" -L "$OUT/modules" -lSafarierCore -Xlinker -rpath -Xlinker "$OUT/modules" "$ROOT/Sources/Safarier/Automation/RunnerAutomationPage.swift" "$ROOT/Sources/Safarier/Automation/RunnerAutomationController.swift" "$ROOT/Sources/Safarier/Automation/RunnerAutomationService.swift" "$ROOT/Tests/SafarierAppTests/RunnerAutomationServiceCases.swift" "$ROOT/scripts/automation-core-tests/RunnerServiceMain.swift" -o "$OUT/service-tests"
FIXTURE="$(mktemp -d "$OUT/fixture.XXXXXXXX")"
trap 'rmdir "$FIXTURE"' EXIT
RUNNER_SERVICE_FIXTURE="$FIXTURE" python3 -c 'import subprocess,sys;r=subprocess.run([sys.argv[1]],timeout=30);sys.exit(r.returncode)' "$OUT/service-tests"
