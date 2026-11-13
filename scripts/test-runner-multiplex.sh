#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/automation-stage7-worker-a"
mkdir -p "$OUT/modules" "$OUT/module-cache" "$OUT/clang-cache"
export CLANG_MODULE_CACHE_PATH="$OUT/clang-cache"
python3 - "$ROOT" "$OUT" <<'PY'
import glob, subprocess, sys
root,out=sys.argv[1:]
common=['xcrun','swiftc','-swift-version','5','-module-cache-path',out+'/module-cache']
subprocess.run(common+['-emit-library','-emit-module','-module-name','SafarierCore','-emit-module-path',out+'/modules/SafarierCore.swiftmodule']+glob.glob(root+'/Sources/SafarierCore/*.swift')+['-o',out+'/modules/libSafarierCore.dylib'],check=True,timeout=90)
subprocess.run(common+['-parse-as-library','-I',out+'/modules','-L',out+'/modules','-lSafarierCore','-Xlinker','-rpath','-Xlinker',out+'/modules',root+'/Tests/SafarierCoreTests/RunnerMultiplexCases.swift',root+'/scripts/automation-core-tests/RunnerMultiplexMain.swift','-o',out+'/multiplex-tests'],check=True,timeout=30)
subprocess.run(common+['-parse-as-library','-I',out+'/modules','-L',out+'/modules','-lSafarierCore','-Xlinker','-rpath','-Xlinker',out+'/modules',root+'/Tests/Fixtures/ControlledRunnerHelper/main.swift','-o',out+'/controlled-helper'],check=True,timeout=30)
import os
env=os.environ.copy(); env['CONTROLLED_HELPER_PATH']=out+'/controlled-helper'; env['STAGE7_ARTIFACT_DIR']=out
subprocess.run([out+'/multiplex-tests'],check=True,timeout=30,env=env)
subprocess.run(common+['-parse-as-library','-I',out+'/modules','-L',out+'/modules','-lSafarierCore','-Xlinker','-rpath','-Xlinker',out+'/modules',root+'/Tests/SafarierCoreTests/ControlledRunnerCases.swift',root+'/scripts/automation-core-tests/ControlledRunnerMain.swift','-o',out+'/controlled-tests'],check=True,timeout=30)
subprocess.run([out+'/controlled-tests'],check=True,timeout=40,env=env)
PY
