#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/arm64-apple-macosx/debug"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swift build --product Safarier --package-path "$ROOT"

core_objects=("$BUILD"/SafarierCore.build/*.swift.o)
support_objects=("$BUILD"/SafarierControlSupport.build/*.o)
binder_objects=("$BUILD"/BinderIdentity.build/*.o)
inventory_objects=("$BUILD"/BundleInventory.build/*.o)

swiftc -parse-as-library \
  -I "$BUILD/Modules" \
  -Xcc -fmodule-map-file="$BUILD/SafarierControlSupport.build/module.modulemap" \
  -Xcc -I -Xcc "$ROOT/Sources/SafarierControlSupport/include" \
  -Xcc -fmodule-map-file="$BUILD/BinderIdentity.build/module.modulemap" \
  -Xcc -I -Xcc "$ROOT/Sources/BinderIdentity/include" \
  -Xcc -fmodule-map-file="$BUILD/BundleInventory.build/module.modulemap" \
  -Xcc -I -Xcc "$ROOT/Sources/BundleInventory/include" \
  "$ROOT/Sources/Safarier/Automation/ControlRuntime.swift" \
  "$ROOT/scripts/control-stale-socket-fixture.swift" \
  "${core_objects[@]}" "${support_objects[@]}" "${binder_objects[@]}" "${inventory_objects[@]}" \
  -lbsm -framework Security -framework CoreFoundation -framework Carbon \
  -o "$TMP/control-stale-socket-fixture"

"$TMP/control-stale-socket-fixture"
