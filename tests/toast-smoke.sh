#!/bin/bash
# 显式验证常驻原生控制条的 AppKit 状态，不操作用户 Chrome 或发送系统输入。
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then exit 2; fi
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d /tmp/copis-chrome-toast-smoke.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/assets"
cp "$root/assets/copis-logo.png" "$scratch/assets/copis-logo.png"
sources=()
for source in "$root"/swift/*.swift; do
  [[ "$(basename "$source")" == main.swift ]] || sources+=("$source")
done
swiftc -O -warnings-as-errors -target "$(uname -m)-apple-macosx14.0" "${sources[@]}" \
  "$root/tests/toast/main.swift" -o "$scratch/toast-tests"
/usr/bin/python3 - "$scratch/toast-tests" <<'PY'
import subprocess
import sys
subprocess.run(sys.argv[1:], check=True, timeout=12)
PY
