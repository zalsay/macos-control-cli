#!/bin/bash
# 只创建本进程非激活控制条，不操作用户应用。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d /tmp/desktop-toast-smoke.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/assets"
cp "$root/assets/copis-logo.png" "$scratch/assets/copis-logo.png"
sources=()
for source in "$root"/swift/*.swift; do
  [[ "$(basename "$source")" == main.swift ]] || sources+=("$source")
done
swiftc -O -warnings-as-errors "${sources[@]}" "$root/tests/application-toast/main.swift" -o "$scratch/toast-tests"
"$scratch/toast-tests"
