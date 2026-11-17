#!/bin/sh
# Installs only the BLE client; does not touch MCC, firmware, or shell profiles.
set -eu
mbc_source_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
mbc_prefix=${HOME:?}/.local
case "${1-}" in
    --help|-h)
        printf '用法：sh mbc/install.sh [--prefix /absolute/path]\n安装 mbc 和 macos-ble-control；默认 ~/.local/bin。不会修改 PATH。\n'
        exit 0 ;;
    --prefix)
        [ "$#" -eq 2 ] || { printf 'ERROR: --prefix 需要绝对路径\n' >&2; exit 2; }
        mbc_prefix=$2 ;;
    '') [ "$#" -eq 0 ] || exit 2 ;;
    *) printf 'ERROR: 未知安装参数\n' >&2; exit 2 ;;
esac
case "$mbc_prefix" in /*) ;; *) printf 'ERROR: 安装前缀必须是绝对路径\n' >&2; exit 2 ;; esac
mbc_runtime=$mbc_prefix/lib/macos-ble-control
mbc_target=$mbc_runtime/macos-ble-control
for mbc_name in mbc macos-ble-control; do
    mbc_link=$mbc_prefix/bin/$mbc_name
    if [ -e "$mbc_link" ] || [ -L "$mbc_link" ]; then
        [ -L "$mbc_link" ] && [ "$(readlink "$mbc_link")" = "$mbc_target" ] || {
            printf 'ERROR: 拒绝覆盖无关命令 %s\n' "$mbc_link" >&2; exit 1;
        }
    fi
done
if [ -e "$mbc_runtime" ] || [ -L "$mbc_runtime" ]; then
    [ -d "$mbc_runtime" ] && [ ! -L "$mbc_runtime" ] &&
        [ -f "$mbc_runtime/.mbc-managed" ] && [ ! -L "$mbc_target" ] || {
        printf 'ERROR: 拒绝覆盖非受管理安装目录 %s\n' "$mbc_runtime" >&2; exit 1;
    }
fi
sh "$mbc_source_dir/build.sh"
mbc_binary=$mbc_source_dir/../target/mbc/macos-ble-control
/usr/bin/codesign --verify --strict "$mbc_binary"
mkdir -p "$mbc_prefix/bin" "$mbc_runtime"
mbc_staging=$(mktemp "$mbc_runtime/.mbc.XXXXXX")
trap 'rm -f "$mbc_staging"' 0
cp "$mbc_binary" "$mbc_staging"
chmod 755 "$mbc_staging"
mv -f "$mbc_staging" "$mbc_target"
printf 'macos-ble-control\n' > "$mbc_runtime/.mbc-managed"
for mbc_name in mbc macos-ble-control; do
    if [ ! -L "$mbc_prefix/bin/$mbc_name" ]; then
        ln -s "$mbc_target" "$mbc_prefix/bin/$mbc_name"
    fi
done
printf 'Installed %s/bin/mbc and %s/bin/macos-ble-control\n' "$mbc_prefix" "$mbc_prefix"
