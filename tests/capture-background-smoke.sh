#!/bin/bash
# 显式只读实际窗口回归；不列入默认无桌面访问 smoke。
set -euo pipefail
if [[ "$(uname -s)" != Darwin || $# != 1 ]]; then
  echo '用法：bash tests/capture-background-smoke.sh <Chrome 窗口ID>' >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d /tmp/copis-background-capture.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
sources=()
for source in "$root"/swift/*.swift; do
  [[ "$(basename "$source")" == main.swift ]] || sources+=("$source")
done
swiftc -O -warnings-as-errors -target "$(uname -m)-apple-macosx14.0" "${sources[@]}" \
  "$root/tests/capture-background/main.swift" -o "$scratch/capture-tests"
/usr/bin/python3 - "$scratch/capture-tests" "$1" <<'PY'
import subprocess
import sys
subprocess.run(sys.argv[1:], check=True, timeout=20)
PY
