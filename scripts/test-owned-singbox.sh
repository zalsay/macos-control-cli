#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${SAFARIER_TEST_BUILD_ROOT:-$ROOT/.build/automation-stage12-worker-b}"
mkdir -p "$OUT"
xcrun swiftc -swift-version 5 "$ROOT/Tests/Fixtures/OwnedSingboxHelper/main.swift" -o "$OUT/owned-helper"
FIXTURE="$(mktemp -d "$OUT/fixture.XXXXXXXX")"
trap 'rmdir "$FIXTURE"' EXIT
OWNED_SINGBOX_HELPER="$OUT/owned-helper" OWNED_SINGBOX_FIXTURE="$FIXTURE" swift test --package-path "$ROOT" --scratch-path "$OUT/swiftpm" --filter OwnedSingboxTests
