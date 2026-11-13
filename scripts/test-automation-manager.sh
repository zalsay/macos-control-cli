#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/automation-stage9-manager"
mkdir -p "$OUT"

STDOUT_LOG="$OUT/stdout.log"
STDERR_LOG="$OUT/stderr.log"
EXIT_CODE_FILE="$OUT/exit-code"

set +e
(
  cd "$ROOT"
  swift test --filter AutomationManagerTests
) >"$STDOUT_LOG" 2>"$STDERR_LOG"
status=$?
set -e

cat "$STDOUT_LOG"
cat "$STDERR_LOG" >&2
printf '%s\n' "$status" >"$EXIT_CODE_FILE"
exit "$status"
