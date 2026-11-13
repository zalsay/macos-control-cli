#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/automation-stage8-worker-a"
mkdir -p "$OUT"
xcrun swiftc -parse-as-library "$ROOT/Sources/Safarier/Automation/NavigationCorrelation.swift" "$ROOT/scripts/automation-core-tests/NavigationCorrelationMain.swift" -o "$OUT/navigation-tests"
"$OUT/navigation-tests"
python3 "$ROOT/scripts/automation-core-tests/Stage8NativeSourceChecks.py"
