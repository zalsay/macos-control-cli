#!/bin/bash
# Focused BLE planning/control checks; no real BLE, GUI or system input.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d /tmp/mcc-espble-native.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
sources=()
for source in "$root"/swift/*.swift; do
    [[ "${source##*/}" == main.swift ]] || sources+=("$source")
done
swiftc -O -warnings-as-errors "${sources[@]}" "$root/tests/espble-native/main.swift" -o "$scratch/tests"
"$scratch/tests"
