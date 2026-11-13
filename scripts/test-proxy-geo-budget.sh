#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${SAFARIER_TEST_BUILD_ROOT:-$ROOT/.build/automation-stage11-worker-b}"
mkdir -p "$OUT"
swift test --package-path "$ROOT" --scratch-path "$OUT/swiftpm" --filter ProxyGeoBudgetTests
