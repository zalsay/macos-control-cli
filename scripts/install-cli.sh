#!/bin/sh
# Install a copy; never replace an unknown existing command or edit shell rc.
set -eu
source_dir=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd -P)
source="$source_dir/sfa"
destination="$HOME/.local/bin/sfa"
[ -f "$source" ] && [ ! -L "$source" ] || { printf '%s\n' '缺少 scripts/sfa。' >&2; exit 1; }
mkdir -p "$HOME/.local/bin"
if [ -e "$destination" ] || [ -L "$destination" ]; then
    if [ -f "$destination" ] && [ ! -L "$destination" ] && cmp -s "$source" "$destination"; then
        chmod 755 "$destination"
        printf '%s\n' "sfa 已安装且内容一致：$destination"
        exit 0
    fi
    printf '%s\n' "拒绝覆盖已有未知命令：$destination" >&2
    exit 1
fi
# noclobber also refuses a destination created after the check above.
(set -C; cat "$source" > "$destination") || { printf '%s\n' '安装失败；未覆盖已有命令。' >&2; exit 1; }
chmod 755 "$destination"
printf '%s\n' "已安装：$destination"
