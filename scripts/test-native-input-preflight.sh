#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/native-input-extraction"
mkdir -p "$OUT/modules" "$OUT/module-cache" "$OUT/clang-cache"
export CLANG_MODULE_CACHE_PATH="$OUT/clang-cache"
python3 - "$ROOT" "$OUT" <<'PY'
import subprocess, sys
root,out=sys.argv[1:]
c=['xcrun','swiftc','-swift-version','5','-module-cache-path',out+'/module-cache']
subprocess.run(c+['-emit-library','-emit-module','-module-name','SafarierCore','-emit-module-path',out+'/modules/SafarierCore.swiftmodule']+[root+'/Sources/SafarierCore/AutomationProtocol.swift',root+'/Sources/SafarierCore/NativeInputPreflight.swift']+['-o',out+'/modules/libSafarierCore.dylib'],check=True,timeout=60)
subprocess.run(c+['-parse-as-library','-I',out+'/modules','-L',out+'/modules','-lSafarierCore','-Xlinker','-rpath','-Xlinker',out+'/modules',root+'/Tests/SafarierCoreTests/NativeInputCases.swift',root+'/scripts/automation-core-tests/NativeInputMain.swift','-o',out+'/native-preflight-tests'],check=True,timeout=30)
subprocess.run([out+'/native-preflight-tests'],check=True,timeout=10)
PY
