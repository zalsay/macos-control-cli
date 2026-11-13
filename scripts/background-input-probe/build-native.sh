#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
P="$ROOT/.build/mcc-safarier-probe"
SWIFT_CACHE_ARGS=()
CLANG_CACHE_ARGS=()
if [ "${1:-}" = "--out-root" ] && [ "$#" -eq 2 ]; then
  P="$2"
  STAGE="$ROOT/.build/automation-gui-pointer-smoke-20261104"
  python3 - "$STAGE" "$P" "create" <<'PYSAFE'
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
SPM="$P/swiftpm"
mkdir -p "$M"
printf 'Building repository modules and YAML dependency through SwiftPM\n'
swift build --package-path "$ROOT" --scratch-path "$SPM" --product SafarierCore
swift build --package-path "$ROOT" --scratch-path "$SPM" --product SafarierNetwork
swift build --package-path "$ROOT" --scratch-path "$SPM" --product SafarierWebKit
swift build --package-path "$ROOT" --scratch-path "$SPM" --target SafarierControlSupport
BIN="$(swift build --package-path "$ROOT" --scratch-path "$SPM" --show-bin-path)"
for module in SafarierCore SafarierNetwork SafarierWebKit Yams; do
  cp -R "$BIN/$module.swiftmodule" "$M/"
done
for library in SafarierCore SafarierNetwork SafarierWebKit; do
  cp "$BIN/lib$library.a" "$M/"
done
libtool -static -o "$M/libSafarierControlSupport.a" "$BIN/SafarierControlSupport.o"
for module in BinderIdentity BundleInventory SafarierObjCSupport SafarierControlSupport; do
  mkdir -p "$M/$module"
  printf 'module %s { umbrella header "%s" export * }\n' "$module" "$ROOT/Sources/$module/include/$module.h" > "$M/$module/module.modulemap"
done
cp -R "$SPM/checkouts/Yams/Sources/CYaml/include" "$M/CYaml"
printf 'MODULES_BUILD_OK\n'
