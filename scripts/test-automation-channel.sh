#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/automation-channel"
mkdir -p "$OUT/modules" "$OUT/module-cache" "$OUT/clang-cache"
export CLANG_MODULE_CACHE_PATH="$OUT/clang-cache"
xcrun swiftc -swift-version 5 -enable-testing -module-cache-path "$OUT/module-cache" -emit-library -emit-module -module-name SafarierCore -emit-module-path "$OUT/modules/SafarierCore.swiftmodule" "$ROOT/Sources/SafarierCore/AutomationChannel.swift" -o "$OUT/modules/libSafarierCore.dylib"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$OUT/module-cache" -I "$OUT/modules" -L "$OUT/modules" -lSafarierCore -Xlinker -rpath -Xlinker "$OUT/modules" "$ROOT/Tests/SafarierCoreTests/AutomationChannelCases.swift" "$ROOT/scripts/automation-core-tests/ChannelMain.swift" -o "$OUT/channel-tests"
python3 -c 'import subprocess,sys; r=subprocess.run([sys.argv[1]],timeout=20); sys.exit(r.returncode)' "$OUT/channel-tests"
