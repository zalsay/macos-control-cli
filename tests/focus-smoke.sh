#!/bin/bash
# 显式指定已有窗口和另一应用；仅焦点切换，不投递键盘鼠标，不主动请求权限。
set -euo pipefail
if [[ "$(uname -s)" != Darwin || $# != 2 ]]; then
  echo '用法（macOS）：bash tests/focus-smoke.sh <Chrome 窗口 ID> <其他应用 PID>' >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d /tmp/copis-chrome-focus-smoke.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
sources=()
for source in "$root"/swift/*.swift; do
  [[ "$(basename "$source")" == main.swift ]] || sources+=("$source")
done
swiftc -O -target "$(uname -m)-apple-macosx14.0" "${sources[@]}" \
  "$root/tests/focus/main.swift" -o "$scratch/focus-tests"
/usr/bin/python3 - "$scratch/focus-tests" "$1" "$2" <<'PY'
import subprocess
import sys
subprocess.run(sys.argv[1:], check=True, timeout=15)
PY
