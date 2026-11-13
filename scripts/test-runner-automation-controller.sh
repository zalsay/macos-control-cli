#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/runner-automation-controller"
mkdir -p "$OUT/modules" "$OUT/module-cache" "$OUT/clang-cache"
export CLANG_MODULE_CACHE_PATH="$OUT/clang-cache"
xcrun swiftc -swift-version 5 -enable-testing -module-cache-path "$OUT/module-cache" -emit-library -emit-module -module-name SafarierCore -emit-module-path "$OUT/modules/SafarierCore.swiftmodule" "$ROOT"/Sources/SafarierCore/*.swift -o "$OUT/modules/libSafarierCore.dylib"
xcrun swiftc -swift-version 5 -D RUNNER_CONTROLLER_STANDALONE -parse-as-library -module-cache-path "$OUT/module-cache" -I "$OUT/modules" -L "$OUT/modules" -lSafarierCore -Xlinker -rpath -Xlinker "$OUT/modules" "$ROOT/Sources/Safarier/Automation/RunnerAutomationController.swift" "$ROOT/Tests/SafarierAppTests/RunnerAutomationControllerCases.swift" "$ROOT/scripts/automation-core-tests/RunnerControllerMain.swift" -o "$OUT/controller-tests"
python3 -c 'import subprocess,sys; r=subprocess.run([sys.argv[1]],timeout=30); sys.exit(r.returncode)' "$OUT/controller-tests"
