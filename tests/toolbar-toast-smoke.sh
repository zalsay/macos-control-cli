#!/bin/bash
# 只操作本进程AppKit对象，不截图、不移动鼠标、不向用户应用输入。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d /tmp/chrome-toolbar-toast.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/assets"
cp "$root/assets/copis-logo.png" "$scratch/assets/copis-logo.png"
sources=()
for source in "$root"/swift/*.swift; do
  [[ "$(basename "$source")" == main.swift ]] || sources+=("$source")
done
swiftc -O -warnings-as-errors "${sources[@]}" "$root/tests/toolbar-toast-ui/main.swift" -o "$scratch/toast-tests"
python3 - "$scratch/toast-tests" <<'PY'
import subprocess,sys
subprocess.run(sys.argv[1:], check=True, timeout=10)
PY
