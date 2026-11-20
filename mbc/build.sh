#!/bin/sh
set -eu
if [ "${1-}" = --help ] || [ "${1-}" = -h ]; then
    printf '用法：sh mbc/build.sh [输出目录]\n默认输出到项目 target/mbc；构建 mbc 和 macos-ble-control，不安装或连接蓝牙。\n'
    exit 0
fi
[ "$#" -le 1 ] || { printf 'ERROR: 最多接受一个输出目录\n' >&2; exit 2; }
mbc_source_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
mbc_output=${1:-$mbc_source_dir/../target/mbc}
[ "$(uname -s)" = Darwin ] || { printf 'ERROR: MBC 仅支持 macOS\n' >&2; exit 1; }
case "$(uname -m)" in
    arm64) mbc_swift_target=arm64-apple-macosx14.0 ;;
    x86_64) mbc_swift_target=x86_64-apple-macosx14.0 ;;
    *) printf 'ERROR: 不支持当前架构\n' >&2; exit 1 ;;
esac
mkdir -p "$mbc_output"
mbc_output=$(CDPATH= cd -P "$mbc_output" && pwd)
mbc_info_plist=$mbc_source_dir/Info.plist
/usr/bin/plutil -lint "$mbc_info_plist"
for mbc_name in mbc macos-ble-control; do
    [ ! -d "$mbc_output/$mbc_name" ] && [ ! -L "$mbc_output/$mbc_name" ] || {
        printf 'ERROR: 拒绝覆盖目录或链接 %s\n' "$mbc_output/$mbc_name" >&2; exit 1;
    }
done
mbc_staging=$(mktemp -d "$mbc_output/.mbc-build.XXXXXX")
trap 'rm -rf "$mbc_staging"' 0
xcrun swiftc -O -warnings-as-errors -target "$mbc_swift_target" \
    "$mbc_source_dir/MBCOptions.swift" "$mbc_source_dir/MBCMain.swift" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$mbc_info_plist" \
    -o "$mbc_staging/macos-ble-control"
/usr/bin/codesign --force --sign "${COPIS_CHROME_SIGN_IDENTITY:--}" \
    --identifier com.copis.macos-ble-control.cli "$mbc_staging/macos-ble-control"
cp "$mbc_staging/macos-ble-control" "$mbc_staging/mbc"
chmod 755 "$mbc_staging/macos-ble-control" "$mbc_staging/mbc"
mv -f "$mbc_staging/macos-ble-control" "$mbc_output/macos-ble-control"
mv -f "$mbc_staging/mbc" "$mbc_output/mbc"
printf 'Built %s/macos-ble-control and %s/mbc\n' "$mbc_output" "$mbc_output"
