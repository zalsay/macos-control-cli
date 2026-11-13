#!/bin/bash
set -euo pipefail
if [ "${MANAGER_TEST_WATCHDOG:-0}" != 1 ]; then
  export MANAGER_TEST_WATCHDOG=1
  exec python3 -c 'import os,signal,subprocess,sys; p=subprocess.Popen([sys.argv[1]],start_new_session=True);
try: sys.exit(p.wait(timeout=60))
except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); p.wait(); print("manager test watchdog timeout",file=sys.stderr); sys.exit(124)' "$0"
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/manager-launch"
mkdir -p "$OUT/modules" "$OUT/module-cache" "$OUT/clang-cache"
export CLANG_MODULE_CACHE_PATH="$OUT/clang-cache"
xcrun swiftc -swift-version 5 -enable-testing -module-cache-path "$OUT/module-cache" -emit-library -emit-module -module-name SafarierCore -emit-module-path "$OUT/modules/SafarierCore.swiftmodule" "$ROOT/Sources/SafarierCore/ManagerLaunchPolicy.swift" -o "$OUT/modules/libSafarierCore.dylib"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$OUT/module-cache" -I "$OUT/modules" -L "$OUT/modules" -lSafarierCore -Xlinker -rpath -Xlinker "$OUT/modules" "$ROOT/Tests/SafarierCoreTests/ManagerLaunchCases.swift" "$ROOT/scripts/automation-core-tests/ManagerLaunchMain.swift" -o "$OUT/manager-tests"
python3 -c 'import subprocess,sys; r=subprocess.run([sys.argv[1]],timeout=20); sys.exit(r.returncode)' "$OUT/manager-tests"

TMP="$(mktemp -d "$OUT/metadata.XXXXXXXX")"
trap 'rm -rf "$TMP"' EXIT
SAFARIER_METADATA_ONLY=1 SAFARIER_SCRIPTING_CANDIDATE=0 SAFARIER_APP_OUT="$TMP/default" "$ROOT/scripts/build-app.sh"
PLIST="$TMP/default/Contents/Info.plist"
[ "$(plutil -extract LSUIElement raw -o - "$PLIST")" = true ]
if /usr/libexec/PlistBuddy -c 'Print :NSAppleScriptEnabled' "$PLIST" >/dev/null 2>&1; then echo "default scripting enabled" >&2; exit 1; fi
if /usr/libexec/PlistBuddy -c 'Print :OSAScriptingDefinition' "$PLIST" >/dev/null 2>&1; then echo "default dictionary enabled" >&2; exit 1; fi
[ ! -e "$TMP/default/Contents/Resources/Safarier.sdef" ]
SAFARIER_METADATA_ONLY=1 SAFARIER_SCRIPTING_CANDIDATE=1 SAFARIER_APP_OUT="$TMP/candidate" "$ROOT/scripts/build-app.sh"
PLIST="$TMP/candidate/Contents/Info.plist"
[ "$(plutil -extract NSAppleScriptEnabled raw -o - "$PLIST")" = true ]
[ "$(plutil -extract OSAScriptingDefinition raw -o - "$PLIST")" = Safarier.sdef ]
cmp "$ROOT/Sources/Safarier/Resources/Safarier.sdef" "$TMP/candidate/Contents/Resources/Safarier.sdef"
mkdir "$TMP/existing"; printf untouched > "$TMP/existing/sentinel"
if SAFARIER_METADATA_ONLY=2 SAFARIER_SCRIPTING_CANDIDATE=0 SAFARIER_APP_OUT="$TMP/existing" SINGBOX_DIR="$TMP/missing-singbox" "$ROOT/scripts/build-app.sh" > "$TMP/invalid-mode.log" 2>&1; then echo "invalid metadata-only mode accepted" >&2; exit 1; fi
grep -q '无效 SAFARIER_METADATA_ONLY' "$TMP/invalid-mode.log" || { echo "invalid mode was not rejected at validation" >&2; exit 1; }
[ "$(cat "$TMP/existing/sentinel")" = untouched ]
if SAFARIER_METADATA_ONLY= SAFARIER_SCRIPTING_CANDIDATE=0 SAFARIER_APP_OUT="$TMP/existing" SINGBOX_DIR="$TMP/missing-singbox" "$ROOT/scripts/build-app.sh" > "$TMP/empty-mode.log" 2>&1; then echo "empty metadata-only mode accepted" >&2; exit 1; fi
grep -q '无效 SAFARIER_METADATA_ONLY' "$TMP/empty-mode.log" || { echo "empty mode was not rejected at validation" >&2; exit 1; }
[ "$(cat "$TMP/existing/sentinel")" = untouched ]
if SAFARIER_METADATA_ONLY=1 SAFARIER_SCRIPTING_CANDIDATE=invalid SAFARIER_APP_OUT="$TMP/existing" "$ROOT/scripts/build-app.sh" > /dev/null 2>&1; then echo "invalid candidate accepted" >&2; exit 1; fi
[ "$(cat "$TMP/existing/sentinel")" = untouched ]
if SAFARIER_METADATA_ONLY=1 SAFARIER_SCRIPTING_CANDIDATE= SAFARIER_APP_OUT="$TMP/empty" "$ROOT/scripts/build-app.sh" > /dev/null 2>&1; then echo "empty candidate accepted" >&2; exit 1; fi
[ ! -e "$TMP/empty" ]
if SAFARIER_METADATA_ONLY=1 SAFARIER_SCRIPTING_CANDIDATE=0 SAFARIER_APP_OUT="$TMP/existing" "$ROOT/scripts/build-app.sh" > /dev/null 2>&1; then echo "existing output accepted" >&2; exit 1; fi
[ "$(cat "$TMP/existing/sentinel")" = untouched ]
if env -u SAFARIER_APP_OUT SAFARIER_METADATA_ONLY=1 SAFARIER_SCRIPTING_CANDIDATE=0 "$ROOT/scripts/build-app.sh" > /dev/null 2>&1; then echo "missing output accepted" >&2; exit 1; fi
echo "PASS: metadata default, candidate, invalid, no-overwrite, explicit-output"
