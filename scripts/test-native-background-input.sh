#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/native-background-input-tests"
mkdir -p "$OUT"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter \
    "$ROOT/Tests/NativeInput/ScopedMouseStateTests.m" \
    -I "$ROOT/Sources/SafarierObjCSupport/include" \
    -framework AppKit -framework WebKit -o "$OUT/ScopedMouseStateTests"
"$OUT/ScopedMouseStateTests"
