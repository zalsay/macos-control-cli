#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/safarier-navigation-retry.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
xcrun swiftc -parse-as-library \
  "$ROOT/Sources/Safarier/Automation/NavigationCorrelation.swift" \
  "$ROOT/scripts/automation-core-tests/NavigationRetryMain.swift" \
  -o "$OUT/navigation-retry-tests"
"$OUT/navigation-retry-tests"
