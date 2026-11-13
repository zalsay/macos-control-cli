#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/control-cli-focused"
mkdir -p "$OUT/modules" "$OUT/module-cache" "$OUT/clang-cache"
export CLANG_MODULE_CACHE_PATH="$OUT/clang-cache"
xcrun swiftc -swift-version 5 -enable-testing -module-cache-path "$OUT/module-cache" -emit-library -emit-module -module-name SafarierCore -emit-module-path "$OUT/modules/SafarierCore.swiftmodule" "$ROOT/Sources/SafarierCore/AutomationProtocol.swift" "$ROOT/Sources/SafarierCore/ControlCommand.swift" "$ROOT/Sources/SafarierCore/ControlProtocol.swift" -o "$OUT/modules/libSafarierCore.dylib"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$OUT/module-cache" -I "$OUT/modules" -L "$OUT/modules" -lSafarierCore -Xlinker -rpath -Xlinker "$OUT/modules" "$ROOT/Tests/SafarierCoreTests/ControlCommandCases.swift" "$ROOT/scripts/automation-core-tests/ControlMain.swift" -o "$OUT/control-tests"
"$OUT/control-tests"
