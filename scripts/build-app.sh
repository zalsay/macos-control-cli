#!/usr/bin/env bash
# 编出 Universal（arm64 + x86_64）release 二进制，组装 dist/Safarier AI.app（Manager）
# 与 dist/Safarier AI Browser.app（Runner），并做本机 ad-hoc 签名。
# Apple 芯片和 Intel 的 Mac 都能用。只在 Mac mini 上跑（需要 Xcode 工具链：多架构 swift build 和 lipo）。
# 环境变量：SAFARIER_VERSION 覆盖版本号（默认 1.0.1），SAFARIER_BUILD 覆盖构建号（默认 git 提交数），
#           SINGBOX_DIR 覆盖自带 sing-box 的目录（默认 .build/sing-box，由 scripts/build-singbox.sh 在编译机上编出来），
#           MIHOMO_DIR 覆盖自带 mihomo 的目录（默认 .build/mihomo，由 scripts/build-mihomo.sh 在编译机上编出来）。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION="${SAFARIER_VERSION:-1.0.1}"
BUILD="${SAFARIER_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
TARGET_ARCH="${SAFARIER_ARCH:-universal}"
BUNDLE_ID="sh.safarier.app"
RUNNER_BUNDLE_ID="sh.safarier.browser"
APP="${SAFARIER_APP_OUT:-$ROOT/dist/Safarier AI.app}"
RUNNER_APP="${SAFARIER_RUNNER_APP_OUT:-$ROOT/dist/Safarier AI Browser.app}"
SINGBOX_DIR="${SINGBOX_DIR:-$ROOT/.build/sing-box}"
MIHOMO_DIR="${MIHOMO_DIR:-$ROOT/.build/mihomo}"

METADATA_ONLY="${SAFARIER_METADATA_ONLY-0}"
case "$METADATA_ONLY" in 0|1) ;; *) echo "无效 SAFARIER_METADATA_ONLY" >&2; exit 1 ;; esac
SCRIPTING_CANDIDATE="${SAFARIER_SCRIPTING_CANDIDATE-0}"
case "$SCRIPTING_CANDIDATE" in 0|1) ;; *) echo "无效 SAFARIER_SCRIPTING_CANDIDATE" >&2; exit 1 ;; esac
SDEF_SOURCE="$ROOT/Sources/Safarier/Resources/Safarier.sdef"
if [ "$SCRIPTING_CANDIDATE" = 1 ] && [ ! -f "$SDEF_SOURCE" ]; then
  echo "缺少候选脚本词典" >&2; exit 1
fi
SCRIPT_KEYS=""
if [ "$SCRIPTING_CANDIDATE" = 1 ]; then
  SCRIPT_KEYS='    <key>NSAppleScriptEnabled</key><true/>
    <key>OSAScriptingDefinition</key><string>Safarier.sdef</string>'
fi

write_manager_metadata() {
  local target="$1"
  cat > "$target/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh-Hans</string>
	<key>CFBundleDisplayName</key>
	<string>Safarier AI</string>
	<key>CFBundleExecutable</key>
	<string>Safarier AI</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Safarier AI</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD}</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
${SCRIPT_KEYS}
	<key>NSCameraUsageDescription</key>
	<string>网页请求使用摄像头时（例如视频会议），Safarier AI 会先询问你。</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>网页请求使用麦克风时（例如视频会议），Safarier AI 会先询问你。</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>Safarier AI 需要自动化权限，以便按照你的指令控制其他应用。</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Safarier AI</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
</dict>
</plist>
PLIST
  plutil -lint "$target/Contents/Info.plist" >/dev/null

  if [ "$SCRIPTING_CANDIDATE" = 1 ]; then cp "$SDEF_SOURCE" "$target/Contents/Resources/Safarier.sdef"; fi
}

write_runner_metadata() {
  local target="$1"
  cat > "$target/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh-Hans</string>
	<key>CFBundleDisplayName</key>
	<string>Safarier AI Browser</string>
	<key>CFBundleExecutable</key>
	<string>Safarier AI Browser</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>${RUNNER_BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Safarier AI Browser</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD}</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSCameraUsageDescription</key>
	<string>网页请求使用摄像头时（例如视频会议），Safarier AI Browser 会先询问你。</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>网页请求使用麦克风时（例如视频会议），Safarier AI Browser 会先询问你。</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Safarier AI Browser</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
</dict>
</plist>
PLIST
  plutil -lint "$target/Contents/Info.plist" >/dev/null
}

write_metadata() {
  write_manager_metadata "$APP"
}

if [ "$METADATA_ONLY" = 1 ]; then
  if [ -z "${SAFARIER_APP_OUT:-}" ]; then echo "metadata-only 需要显式 SAFARIER_APP_OUT" >&2; exit 1; fi
  if [ -e "$APP" ] || [ -L "$APP" ]; then echo "metadata-only 不覆盖已有输出" >&2; exit 1; fi
  mkdir "$APP"
  mkdir -p "$APP/Contents/Resources"
  write_metadata
  exit 0
fi

ARCHS_EXPECTED="arm64 x86_64"

# lipo -archs 的输出同时有 arm64 和 x86_64。
is_universal() {
  local archs
  archs=" $(lipo -archs "$1" 2>/dev/null || true) "
  [[ "$archs" == *" arm64 "* && "$archs" == *" x86_64 "* ]]
}

# 编译机交回的是两个单架构切片（Linux 上没有 lipo），在这里合并成 Universal。
if ! { [ -f "$SINGBOX_DIR/sing-box" ] && is_universal "$SINGBOX_DIR/sing-box"; } \
   && [ -f "$SINGBOX_DIR/sing-box-arm64" ] && [ -f "$SINGBOX_DIR/sing-box-amd64" ]; then
  echo "==> 合并 sing-box 切片：lipo -create"
  lipo -create -output "$SINGBOX_DIR/sing-box" "$SINGBOX_DIR/sing-box-arm64" "$SINGBOX_DIR/sing-box-amd64"
  chmod 755 "$SINGBOX_DIR/sing-box"
fi
for item in sing-box LICENSE COPYING SOURCE; do
  if [ ! -f "$SINGBOX_DIR/$item" ]; then
    echo "缺少 $SINGBOX_DIR/$item。先在编译机上编自带的 sing-box：" >&2
    echo "  remote-build --fetch out/sing-box:.build -- scripts/build-singbox.sh" >&2
    exit 1
  fi
done
is_universal "$SINGBOX_DIR/sing-box" \
  || { echo "$SINGBOX_DIR/sing-box 不是 Universal（需要 $ARCHS_EXPECTED，实际：$(lipo -archs "$SINGBOX_DIR/sing-box" 2>/dev/null || echo 不是 Mach-O)）" >&2; exit 1; }
# VLESS Reality 和 fp 指纹要 uTLS；不带 with_utls 编的 sing-box 遇到这类节点会启动失败。
if ! "$SINGBOX_DIR/sing-box" version | grep -q 'with_utls'; then
  echo "警告：$SINGBOX_DIR/sing-box 没有编进 with_utls，VLESS Reality 节点会连不上" >&2
fi

# mihomo：Clash 订阅的节点用它运行，和 sing-box 一样要求是 Universal、带齐许可证文件。
if ! { [ -f "$MIHOMO_DIR/mihomo" ] && is_universal "$MIHOMO_DIR/mihomo"; } \
   && [ -f "$MIHOMO_DIR/mihomo-arm64" ] && [ -f "$MIHOMO_DIR/mihomo-amd64" ]; then
  echo "==> 合并 mihomo 切片：lipo -create"
  lipo -create -output "$MIHOMO_DIR/mihomo" "$MIHOMO_DIR/mihomo-arm64" "$MIHOMO_DIR/mihomo-amd64"
  chmod 755 "$MIHOMO_DIR/mihomo"
fi
for item in mihomo LICENSE COPYING SOURCE; do
  if [ ! -f "$MIHOMO_DIR/$item" ]; then
    echo "缺少 $MIHOMO_DIR/${item}。先在编译机上编自带的 mihomo：" >&2
    echo "  remote-build --fetch out/mihomo:.build -- scripts/build-mihomo.sh" >&2
    exit 1
  fi
done
is_universal "$MIHOMO_DIR/mihomo" \
  || { echo "$MIHOMO_DIR/mihomo 不是 Universal（需要 $ARCHS_EXPECTED，实际：$(lipo -archs "$MIHOMO_DIR/mihomo" 2>/dev/null || echo 不是 Mach-O)）" >&2; exit 1; }

echo "==> swift build -c release --arch arm64 --arch x86_64"
swift build -c release --arch arm64 --arch x86_64 --product Safarier
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Safarier"
is_universal "$BIN" || { echo "$BIN 不是 Universal：$(lipo -archs "$BIN")" >&2; exit 1; }

echo "==> 生成图标"
ICON_WORK="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK"' EXIT
swift "$ROOT/scripts/make-icon.swift" "$ICON_WORK/icon.png"
ICONSET="$ICON_WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
  sips -z "${spec%%:*}" "${spec%%:*}" "$ICON_WORK/icon.png" --out "$ICONSET/icon_${spec#*:}.png" >/dev/null
done
APP_ICON_ICNS="$ICON_WORK/AppIcon.icns"
iconutil -c icns "$ICONSET" -o "$APP_ICON_ICNS"

# 组装嵌套的 Helper Runner (Safarier AI Browser.app)
HELPER_RUNNER="$APP/Contents/Helpers/Safarier AI Browser.app"

echo "==> 组装 Manager ($APP) 与 Runner ($HELPER_RUNNER) [$TARGET_ARCH]"
rm -rf "$APP" "$RUNNER_APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/ThirdParty/sing-box" "$APP/Contents/Resources/ThirdParty/mihomo"

mkdir -p "$HELPER_RUNNER/Contents/MacOS" "$HELPER_RUNNER/Contents/Resources"
mkdir -p "$HELPER_RUNNER/Contents/Helpers"

case "$TARGET_ARCH" in
  universal)
    cp "$BIN" "$APP/Contents/MacOS/Safarier AI"
    cp "$BIN" "$HELPER_RUNNER/Contents/MacOS/Safarier AI Browser"
    cp "$SINGBOX_DIR/sing-box" "$APP/Contents/Helpers/sing-box"
    cp "$SINGBOX_DIR/sing-box" "$HELPER_RUNNER/Contents/Helpers/sing-box"
    cp "$MIHOMO_DIR/mihomo" "$APP/Contents/Helpers/mihomo"
    cp "$MIHOMO_DIR/mihomo" "$HELPER_RUNNER/Contents/Helpers/mihomo"
    ;;
  arm64|x86_64)
    lipo "$BIN" -thin "$TARGET_ARCH" -output "$APP/Contents/MacOS/Safarier AI"
    lipo "$BIN" -thin "$TARGET_ARCH" -output "$HELPER_RUNNER/Contents/MacOS/Safarier AI Browser"
    lipo "$SINGBOX_DIR/sing-box" -thin "$TARGET_ARCH" -output "$APP/Contents/Helpers/sing-box"
    lipo "$SINGBOX_DIR/sing-box" -thin "$TARGET_ARCH" -output "$HELPER_RUNNER/Contents/Helpers/sing-box"
    lipo "$MIHOMO_DIR/mihomo" -thin "$TARGET_ARCH" -output "$APP/Contents/Helpers/mihomo"
    lipo "$MIHOMO_DIR/mihomo" -thin "$TARGET_ARCH" -output "$HELPER_RUNNER/Contents/Helpers/mihomo"
    ;;
  *)
    echo "未知 SAFARIER_ARCH=$TARGET_ARCH（支持 universal、arm64、x86_64）" >&2
    exit 1
    ;;
esac

# 兼容符号链接
ln -sf "Safarier AI" "$APP/Contents/MacOS/Safarier"
ln -sf "Safarier AI Browser" "$HELPER_RUNNER/Contents/MacOS/Safarier"

chmod 755 "$APP/Contents/MacOS/Safarier AI" "$APP/Contents/MacOS/Safarier" "$APP/Contents/Helpers/sing-box" "$APP/Contents/Helpers/mihomo"
chmod 755 "$HELPER_RUNNER/Contents/MacOS/Safarier AI Browser" "$HELPER_RUNNER/Contents/MacOS/Safarier" "$HELPER_RUNNER/Contents/Helpers/sing-box" "$HELPER_RUNNER/Contents/Helpers/mihomo"

printf 'APPL????' > "$APP/Contents/PkgInfo"
printf 'APPL????' > "$HELPER_RUNNER/Contents/PkgInfo"

cp "$APP_ICON_ICNS" "$APP/Contents/Resources/AppIcon.icns"
cp "$APP_ICON_ICNS" "$HELPER_RUNNER/Contents/Resources/AppIcon.icns"

cp "$SINGBOX_DIR/LICENSE" "$SINGBOX_DIR/COPYING" "$SINGBOX_DIR/SOURCE" "$APP/Contents/Resources/ThirdParty/sing-box/"
cp "$MIHOMO_DIR/LICENSE" "$MIHOMO_DIR/COPYING" "$MIHOMO_DIR/SOURCE" "$APP/Contents/Resources/ThirdParty/mihomo/"

if [ -x "$ROOT/.build/dsh/bin/dsh" ]; then
  echo "==> 打包 Safarier 内置 DeepSeek Harness ($TARGET_ARCH)"
  mkdir -p "$APP/Contents/Resources/dsh"
  rsync -a --delete \
    --exclude ".git" \
    --exclude "*.log" \
    "$ROOT/.build/dsh/" "$APP/Contents/Resources/dsh/"
fi

write_manager_metadata "$APP"
write_runner_metadata "$HELPER_RUNNER"

echo "==> 同步生成独立 Runner 应用 ($RUNNER_APP)"
cp -R "$HELPER_RUNNER" "$RUNNER_APP"

echo "==> ad-hoc 签名"
if [ -d "$APP/Contents/Resources/dsh" ]; then
  find "$APP/Contents/Resources/dsh" -type f \( -name "*.node" -o -name "*.dylib" -o -perm +111 \) 2>/dev/null | while read -r native_bin; do
    if file "$native_bin" 2>/dev/null | grep -q "Mach-O"; then
      codesign -s - --force "$native_bin" 2>/dev/null || true
    fi
  done
fi
# 由内向外签：先签里面的 sing-box 和 mihomo，再签 Helper Runner，最后签主 App
codesign -s - --force --identifier sh.safarier.sing-box "$APP/Contents/Helpers/sing-box"
codesign -s - --force --identifier sh.safarier.sing-box "$HELPER_RUNNER/Contents/Helpers/sing-box"
codesign -s - --force --identifier sh.safarier.mihomo "$APP/Contents/Helpers/mihomo"
codesign -s - --force --identifier sh.safarier.mihomo "$HELPER_RUNNER/Contents/Helpers/mihomo"
codesign -s - --force --identifier "$RUNNER_BUNDLE_ID" "$HELPER_RUNNER"
codesign -s - --force --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"

codesign -s - --force --identifier sh.safarier.sing-box "$RUNNER_APP/Contents/Helpers/sing-box"
codesign -s - --force --identifier sh.safarier.mihomo "$RUNNER_APP/Contents/Helpers/mihomo"
codesign -s - --force --identifier "$RUNNER_BUNDLE_ID" "$RUNNER_APP"
codesign --verify --deep --strict "$RUNNER_APP"

for binary in "$APP/Contents/MacOS/Safarier AI" "$APP/Contents/Helpers/sing-box" "$APP/Contents/Helpers/mihomo"; do
  if [ "$TARGET_ARCH" = "universal" ]; then
    is_universal "$binary" || { echo "$binary 不是 Universal：$(lipo -archs "$binary")" >&2; exit 1; }
  else
    [ "$(lipo -archs "$binary")" = "$TARGET_ARCH" ] || { echo "$binary 架构不是 $TARGET_ARCH：$(lipo -archs "$binary")" >&2; exit 1; }
  fi
  echo "    ${binary#"$APP/"}：$(lipo -archs "$binary")"
done

echo "==> 完成："
echo "    Manager App: ${APP}（${VERSION} build ${BUILD}，arch：${TARGET_ARCH}）"
echo "    Runner App:  ${RUNNER_APP}（${VERSION} build ${BUILD}，arch：${TARGET_ARCH}）"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Format|Signature)=' || true
codesign -dv "$RUNNER_APP" 2>&1 | grep -E '^(Identifier|Format|Signature)=' || true
