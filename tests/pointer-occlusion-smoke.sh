#!/bin/bash
# 显式只读回归：临时激活 Chrome 并显示受控浮层，验证后恢复前台；不点击、不截图。
set -euo pipefail
if [[ "$(uname -s)" != Darwin || $# != 1 ]]; then
  echo '用法：bash tests/pointer-occlusion-smoke.sh <Chrome 窗口ID>' >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d /tmp/copis-pointer-occlusion.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
sources=()
for source in "$root"/swift/*.swift; do
  [[ "$(basename "$source")" == main.swift ]] || sources+=("$source")
done
swiftc -O -warnings-as-errors -target "$(uname -m)-apple-macosx14.0" "${sources[@]}" \
  "$root/tests/pointer-occlusion/main.swift" -o "$scratch/pointer-tests"
/usr/bin/python3 - "$scratch/pointer-tests" "$1" <<'PY'
import subprocess
import sys
subprocess.run(sys.argv[1:], check=True, timeout=15)
PY
