#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
[[ $(uname -s) == Linux ]] || { echo 'Linux package must be built on Linux.' >&2; exit 1; }
case "${1:-release}" in
  release) mode=release; profile=release ;;
  debug) mode=debug; profile=dev ;;
  *) echo 'Usage: ./build.sh [release|debug]' >&2; exit 1 ;;
esac
case $(rustc -vV | sed -n 's/^host: //p') in
  aarch64-unknown-linux-gnu) arch=arm64 ;;
  x86_64-unknown-linux-gnu) arch=x64 ;;
  *) echo 'Only native Linux GNU arm64/x86_64 toolchains are supported.' >&2; exit 1 ;;
esac
version=$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$root/Cargo.toml" | head -n 1)
name=mcc-$version-linux-$arch
if [[ -e $root/dist/$name ]]; then
  echo "Package already exists: $root/dist/$name; move it aside before rebuilding." >&2; exit 1
fi
target=${CARGO_TARGET_DIR:-$root/target}
mkdir -p "$root/dist"
staging=$(mktemp -d "$root/dist/.linux-build.XXXXXX")
trap 'rm -rf "$staging"' EXIT
package=$staging/$name
mkdir -p "$package/libexec" "$package/source"
# Single-job builds are the default to bound memory and disk pressure.
cargo build --locked --manifest-path "$root/Cargo.toml" --target-dir "$target" \
  --profile "$profile" --jobs "${MCC_BUILD_JOBS:-1}" --bin mcc --bin mcc-linux-helper >&2
cp "$target/$mode/mcc" "$target/$mode/mcc-linux-helper" "$package/libexec/"
cp "$root/linux/mcc" "$package/mcc"
cp "$root/linux/install.sh" "$package/install.sh"
cp "$root/LICENSE" "$root/README.md" "$root/README.zh-CN.md" "$package/"
cp -R "$root/docs" "$package/"
cp -R "$root/src" "$root/tests" "$root/linux" "$root/docs" "$package/source/"
cp "$root/Cargo.toml" "$root/Cargo.lock" "$root/build.sh" "$root/install.sh" "$root/LICENSE" "$root/README.md" "$root/README.zh-CN.md" "$package/source/"
chmod 755 "$package/mcc" "$package/install.sh" "$package/libexec/"*
cat > "$package/module.json" <<JSON
{"name":"mcc-linux-x11","version":"$version","platform":"linux","arch":"$arch","protocolVersion":1,"entrypoint":"mcc","helper":"libexec/mcc-linux-helper"}
JSON
tar -czf "$staging/$name.tar.gz" -C "$staging" "$name"
mv "$package" "$root/dist/$name"
mv "$staging/$name.tar.gz" "$root/dist/$name.tar.gz"
(cd "$root/dist" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
printf 'Linux X11 package: %s\n' "$root/dist/$name" >&2
