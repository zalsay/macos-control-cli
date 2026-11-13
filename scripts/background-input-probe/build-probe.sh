#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
P="$ROOT/.build/mcc-safarier-probe"
SWIFT_CACHE_ARGS=()
CLANG_CACHE_ARGS=()
if [ "${1:-}" = "--out-root" ] && [ "$#" -eq 2 ]; then
  P="$2"
  STAGE="$ROOT/.build/automation-gui-pointer-smoke-20261104"
  python3 - "$STAGE" "$P" "existing" <<'PYSAFE'
import os, pathlib, stat, sys
stage, out = (pathlib.Path(x) for x in sys.argv[1:3])
if not stage.is_absolute() or not out.is_absolute() or '..' in out.parts or out.parent != stage:
    sys.exit('output must be a direct new child of the authorized stage')
def check(p, private=False):
    st = os.lstat(p)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or (st.st_mode & (0o077 if private else 0o022)):
        sys.exit('unsafe directory: ' + str(p))
for p in [*reversed(stage.parents), stage]:
    if p.is_symlink(): sys.exit('symlink in stage path')
check(stage, True)
if sys.argv[3] == 'create':
    os.mkdir(out, 0o700)
else:
    check(out, True)
    for name in ('tmp', 'clang-cache', 'swift-cache', 'static-modules'):
        check(out / name, True)
PYSAFE
  umask 077
  SWIFT_CACHE_ARGS=(-module-cache-path "$P/swift-cache")
  CLANG_CACHE_ARGS=(-fmodules-cache-path="$P/clang-cache")
  export TMPDIR="$P/tmp" CLANG_MODULE_CACHE_PATH="$P/clang-cache" SWIFT_MODULECACHE_PATH="$P/swift-cache"
  mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULECACHE_PATH"
elif [ "$#" -ne 0 ]; then
  echo "usage: $0 [--out-root ABSOLUTE_STAGE_CHILD]" >&2; exit 2
fi
M="$P/static-modules"
APP="$P/BackgroundInputProbe.app"
if [ "$#" -ne 0 ]; then
  [ ! -e "$APP" ] && [ ! -L "$APP" ] || { echo "App output already exists" >&2; exit 1; }
  mkdir "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.codex.safarier.background-input-probe</string><key>CFBundleName</key><string>Safarier Background Input Probe</string><key>CFBundleExecutable</key><string>BackgroundInputProbe</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/><key>CFBundleVersion</key><string>2</string><key>NSHighResolutionCapable</key><true/><key>LSMinimumSystemVersion</key><string>14.0</string></dict></plist>
PLIST
cp "$ROOT/scripts/background-input-probe/fixture.html" "$APP/Contents/Resources/fixture.html"
SOURCES=()
while IFS= read -r p; do SOURCES+=("$p"); done < <(find "$ROOT/Sources/Safarier" -name '*.swift' ! -path "$ROOT/Sources/Safarier/main.swift" | sort)
xcrun swiftc "${SWIFT_CACHE_ARGS[@]}" -swift-version 5 -D SAFARIER_NATIVE_PROBE -parse-as-library -I "$M" -L "$M" -Xcc -I -Xcc "$ROOT/Sources/BinderIdentity/include" -lSafarierCore -lSafarierNetwork -lSafarierWebKit -lSafarierControlSupport -lbsm "${SOURCES[@]}" "$ROOT/scripts/background-input-probe/ProbeMain.swift" "$ROOT/scripts/background-input-probe/NativeEvents.swift" -o "$APP/Contents/MacOS/BackgroundInputProbe"
codesign --force --sign - --identifier org.codex.safarier.background-input-probe "$APP" 2>&1
printf 'PROBE_BUILD_OK %s\n' "$APP"
