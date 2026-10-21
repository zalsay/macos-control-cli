#!/bin/bash
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "[copis-chrome] 原生功能包仅支持在 macOS 上构建" >&2
  exit 1
fi

case "${1:-release}" in
  release) BUILD_MODE="release"; BUILD_PROFILE="release" ;;
  debug) BUILD_MODE="debug"; BUILD_PROFILE="dev" ;;
  *) echo "用法：./build.sh [release|debug]" >&2; exit 1 ;;
esac
RUST_HOST="$(rustc -vV | sed -n 's/^host: //p')"
case "$RUST_HOST" in
  aarch64-apple-darwin) PACKAGE_ARCH="arm64"; SWIFT_TARGET="arm64-apple-macosx14.0" ;;
  x86_64-apple-darwin) PACKAGE_ARCH="x64"; SWIFT_TARGET="x86_64-apple-macosx14.0" ;;
  *) echo "[copis-chrome] 不支持当前构建架构" >&2; exit 1 ;;
esac

# 同一包始终使用宿主平台编译两个二进制，不复用其他平台产物。
PACKAGE_VERSION="$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$PACKAGE_DIR/Cargo.toml" | head -n 1)"
PACKAGE_NAME="copis-chrome-${PACKAGE_VERSION}-darwin-${PACKAGE_ARCH}"
PACKAGE_OUTPUT="$PACKAGE_DIR/dist/$PACKAGE_NAME"
mkdir -p "$PACKAGE_DIR/dist"
PACKAGE_STAGING="$(mktemp -d "$PACKAGE_DIR/dist/.build.XXXXXX")"
trap 'rm -rf "$PACKAGE_STAGING"' EXIT
PACKAGE_BUILD="$PACKAGE_STAGING/$PACKAGE_NAME"
mkdir -p "$PACKAGE_BUILD"
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --manifest-path "$PACKAGE_DIR/Cargo.toml" --target-dir "$PACKAGE_DIR/target" --target "$RUST_HOST" --profile "$BUILD_PROFILE" >&2
swiftc -O -target "$SWIFT_TARGET" "$PACKAGE_DIR"/swift/*.swift -o "$PACKAGE_BUILD/copis-chrome-helper"
cp "$PACKAGE_DIR/target/$RUST_HOST/$BUILD_MODE/copis-chrome" "$PACKAGE_BUILD/copis-chrome"
chmod 755 "$PACKAGE_BUILD/copis-chrome" "$PACKAGE_BUILD/copis-chrome-helper"

# 为两项二进制设置明确 identifier；系统权限是否沿用仍由 macOS TCC 决定。
# 分发时可通过 COPIS_CHROME_SIGN_IDENTITY 指定 Developer ID；默认仅本机 ad-hoc 签名。
PACKAGE_SIGN_IDENTITY="${COPIS_CHROME_SIGN_IDENTITY:--}"
codesign --force --sign "$PACKAGE_SIGN_IDENTITY" --identifier com.copis.chrome-desktop.helper "$PACKAGE_BUILD/copis-chrome-helper"
codesign --force --sign "$PACKAGE_SIGN_IDENTITY" --identifier com.copis.chrome-desktop.cli "$PACKAGE_BUILD/copis-chrome"
cp "$PACKAGE_DIR/USAGE.md" "$PACKAGE_BUILD/USAGE.md"
cp "$PACKAGE_DIR/LICENSE" "$PACKAGE_BUILD/LICENSE"
cp "$PACKAGE_DIR/README.md" "$PACKAGE_DIR/README.zh-CN.md" "$PACKAGE_BUILD/"
cp -R "$PACKAGE_DIR/docs" "$PACKAGE_BUILD/docs"
mkdir -p "$PACKAGE_BUILD/assets" "$PACKAGE_BUILD/source/assets" "$PACKAGE_BUILD/source"
cp "$PACKAGE_DIR/assets/copis-logo.png" "$PACKAGE_BUILD/assets/copis-logo.png"
cp "$PACKAGE_DIR/assets/copis-logo.png" "$PACKAGE_BUILD/source/assets/copis-logo.png"
cp -R "$PACKAGE_DIR/src" "$PACKAGE_DIR/swift" "$PACKAGE_DIR/tests" "$PACKAGE_DIR/docs" "$PACKAGE_BUILD/source/"
cp "$PACKAGE_DIR/Cargo.toml" "$PACKAGE_DIR/Cargo.lock" "$PACKAGE_DIR/build.sh" "$PACKAGE_DIR/README.md" "$PACKAGE_DIR/README.zh-CN.md" "$PACKAGE_DIR/USAGE.md" "$PACKAGE_DIR/LICENSE" "$PACKAGE_DIR/.gitignore" "$PACKAGE_BUILD/source/"
cat > "$PACKAGE_BUILD/module.json" <<MANIFEST
{
  "name": "chrome-desktop-cli",
  "version": "$PACKAGE_VERSION",
  "platform": "darwin",
  "arch": "$PACKAGE_ARCH",
  "minimumOsVersion": "14.0",
  "protocolVersion": 1,
  "entrypoint": "copis-chrome",
  "helper": "copis-chrome-helper"
}
MANIFEST

# 包内相对路径完整，可以整体解压到任意稳定位置使用。
tar -czf "$PACKAGE_STAGING/$PACKAGE_NAME.tar.gz" -C "$PACKAGE_STAGING" "$PACKAGE_NAME"
if [[ -e "$PACKAGE_OUTPUT" ]]; then rm -rf "$PACKAGE_OUTPUT"; fi
mv "$PACKAGE_BUILD" "$PACKAGE_OUTPUT"
mv "$PACKAGE_STAGING/$PACKAGE_NAME.tar.gz" "$PACKAGE_DIR/dist/$PACKAGE_NAME.tar.gz"
(cd "$PACKAGE_DIR/dist" && shasum -a 256 "$PACKAGE_NAME.tar.gz" > "$PACKAGE_NAME.tar.gz.sha256")
echo "[copis-chrome] 功能包已生成：$PACKAGE_OUTPUT" >&2
echo "[copis-chrome] 分发归档：$PACKAGE_DIR/dist/$PACKAGE_NAME.tar.gz" >&2
