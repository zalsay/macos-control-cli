#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/automation-stage9-worker-c/deadline-fixture"
mkdir -p "$OUT/modules" "$OUT/module-cache" "$OUT/clang-cache"
export CLANG_MODULE_CACHE_PATH="$OUT/clang-cache"
# Insert only scheduling delay in a private copy; coordinator decisions remain production code.
python3 - "$ROOT/Sources/SafarierCore/AutomationScriptCoordinator.swift" "$OUT/Coordinator.swift" <<'PY'
import pathlib, sys
s=pathlib.Path(sys.argv[1]).read_text()
worker='            guard self.markStarted(key) else { return }'
timer='            self?.finish(key, code: .timeout)'
assert s.count(worker)==s.count(timer)==1
s=s.replace(worker, '            if getenv("STAGE9_DELAY_WORKER") != nil { try? await Task.sleep(nanoseconds: 80_000_000) }\n'+worker)
s=s.replace(timer, '            if getenv("STAGE9_DELAY_TIMER") != nil { try? await Task.sleep(nanoseconds: 100_000_000) }\n'+timer)
timerStart='            let now = DispatchTime.now().uptimeNanoseconds'
assert s.count(timerStart)==1
s=s.replace(timerStart, '            if getenv("STAGE9_DELAY_TIMER_START") != nil { try? await Task.sleep(nanoseconds: 200_000_000) }\n'+timerStart)
pathlib.Path(sys.argv[2]).write_text(s)
PY
sources=(); for f in "$ROOT"/Sources/SafarierCore/*.swift; do [[ "$f" == */AutomationScriptCoordinator.swift ]] || sources+=("$f"); done
xcrun swiftc -swift-version 5 -module-cache-path "$OUT/module-cache" -emit-library -emit-module -module-name SafarierCore -emit-module-path "$OUT/modules/SafarierCore.swiftmodule" "${sources[@]}" "$OUT/Coordinator.swift" -o "$OUT/modules/libSafarierCore.dylib"
xcrun swiftc -swift-version 5 -parse-as-library -I "$OUT/modules" -L "$OUT/modules" -lSafarierCore -Xlinker -rpath -Xlinker "$OUT/modules" "$ROOT/scripts/automation-core-tests/Stage9DeadlineMain.swift" -o "$OUT/tests"
for mode in prestart late cancel timerstart; do python3 -c 'import subprocess,sys; sys.exit(subprocess.run(sys.argv[1:],timeout=10).returncode)' "$OUT/tests" "$mode"; done
