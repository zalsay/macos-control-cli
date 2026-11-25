#!/bin/bash
# Pass the release scratch/out directory containing the matching targets and module maps.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(cd "${1:?release scratch/out required}" && pwd); prod="$out/Products/Release"; maps="$out/Intermediates.noindex/GeneratedModuleMaps"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
a="$tmp/Fixture.app"; runner="$a/Contents/Helpers/Safarier AI Browser.app/Contents/MacOS"; mkdir -p "$a/Contents/MacOS" "$runner"
printf '#include <unistd.h>\nint main(){for(;;)pause();}\n'| cc -x c - -o "$tmp/unrelated"
cp "$tmp/unrelated" "$a/Contents/MacOS/fixture"; cp "$tmp/unrelated" "$runner/Safarier AI Browser"
plutil -create xml1 "$a/Contents/Info.plist"; plutil -insert CFBundleExecutable -string fixture "$a/Contents/Info.plist"
flags=(); for mod in SafarierControlSupport BinderIdentity BundleInventory; do flags+=(-Xcc "-fmodule-map-file=$maps/$mod.modulemap" -Xcc "-I$PWD/Sources/$mod/include"); done
cc -I Sources/SafarierControlSupport/include Sources/SafarierControlSupport/FullExit.c Tests/Fixtures/ManagerFullExit/main.c -lbsm -o "$tmp/identity"; "$tmp/identity"
xcrun swiftc -parse-as-library -I "$prod" "${flags[@]}" Sources/Safarier/ManagerGUI/ManagerExitInventory.swift Tests/Fixtures/ManagerFullExit/Inventory.swift "$prod"/{SafarierCore,SafarierControlSupport,BinderIdentity,BundleInventory}.o -lbsm -framework Carbon -framework Security -o "$tmp/smoke"
"$tmp/smoke" "$a"
