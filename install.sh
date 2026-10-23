#!/bin/sh
# 本地用户级安装；不联网、不修改 shell 配置、不启动桌面控制。
set -eu
fail() { printf '[mcc] %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
用法：sh install.sh [--prefix <绝对路径>] [--package <功能包目录>]

默认：~/.local/lib/macos-control-cli/<version>/ 保存完整功能包，~/.local/bin/mcc 提供命令。
源码目录会优先安装已构建产物；没有产物时调用现有 build.sh（需要 Rust/Swift）。
已解压功能包直接安装，无需 Rust、Swift、Python、Node.js 或 sudo。
--prefix   自定义用户级安装前缀，命令位于 <prefix>/bin/mcc。
--package  显式选择已解压功能包目录。
--help     显示本帮助，不安装或创建目录。

不覆盖无关 mcc 命令；同版本内容不同会拒绝覆盖，升级使用新的版本目录。
不修改 PATH 或 shell 配置；必要时输出当前终端的 PATH 激活命令。
更新前请结束自己旧版本的 daemon，不要停止别人的控制会话。
HELP
}
safe_version() {
    case "$1" in ''|*[!0-9A-Za-z.+-]*|*..*|[!0-9]*) return 1 ;; esac
    return 0
}
prefix= package=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --prefix|--package)
            [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 需要非空参数"
            if [ "$1" = --prefix ]; then prefix=$2; else package=$2; fi
            shift 2 ;;
        *) fail "未知参数：$1；请运行 sh install.sh --help" ;;
    esac
done
if [ -z "$prefix" ]; then
    [ -n "${HOME-}" ] || fail '无法定位 HOME，请使用 --prefix'
    prefix=$HOME/.local
fi
case "$prefix" in /*) ;; *) fail '--prefix 必须是绝对路径' ;; esac
case "$prefix" in /|*:*) fail '安装前缀不能是根目录或包含 PATH 分隔符' ;; esac
case "$prefix" in *'
'*) fail '安装前缀不能包含换行' ;; esac
if printf '%s' "$prefix" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null; then fail '安装前缀不能包含控制字符'; fi
[ "$(uname -s)" = Darwin ] || fail '仅支持 macOS 14 及以上版本'
os_major=$(/usr/bin/sw_vers -productVersion); os_major=${os_major%%.*}
[ "$os_major" -ge 14 ] || fail '需要 macOS 14 及以上版本'
case "$(uname -m)" in arm64) arch=arm64 ;; x86_64) arch=x64 ;; *) fail '不支持当前架构' ;; esac
source_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
if [ -z "$package" ]; then
    if [ -f "$source_dir/module.json" ]; then
        package=$source_dir
    elif [ -f "$source_dir/Cargo.toml" ] && [ -f "$source_dir/build.sh" ]; then
        version=$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$source_dir/Cargo.toml" | head -n 1)
        safe_version "$version" || fail '源码版本无效'
        package=$source_dir/dist/copis-chrome-$version-darwin-$arch
        if [ ! -f "$package/module.json" ] || [ ! -x "$package/mcc" ] || [ ! -f "$package/install.sh" ] || ! cmp -s "$source_dir/install.sh" "$package/install.sh"; then
            printf '[mcc] 本机产物或安装脚本快照不完整，调用已有 build.sh 构建。\n'
            (cd "$source_dir" && bash ./build.sh)
        fi
    else
        fail '未找到本地功能包；请通过 --package 指定目录'
    fi
fi
[ -d "$package" ] || fail '功能包目录不存在'
package=$(CDPATH= cd -P "$package" && pwd)
field() { /usr/bin/plutil -extract "$1" raw -o - "$package/module.json"; }
[ "$(field name)" = chrome-desktop-cli ] || fail '功能包名称不匹配'
[ "$(field platform)" = darwin ] && [ "$(field arch)" = "$arch" ] || fail '功能包平台或架构不匹配'
version=$(field version); safe_version "$version" || fail '功能包版本无效'
for item in module.json mcc desktop-control copis-chrome copis-chrome-helper install.sh assets/copis-logo.png LICENSE USAGE.md README.md README.zh-CN.md source/Cargo.toml source/install.sh; do
    [ -f "$package/$item" ] && [ ! -L "$package/$item" ] || fail "功能包不完整或含不支持的链接：$item"
done
for item in assets docs source; do
    [ -d "$package/$item" ] && [ ! -L "$package/$item" ] || fail "功能包目录不完整或含不支持的链接：$item"
done
for item in mcc desktop-control copis-chrome copis-chrome-helper; do
    [ -x "$package/$item" ] || fail "文件不可执行：$item"
    /usr/bin/codesign --verify --strict "$package/$item" 2>/dev/null || fail "代码签名校验失败：$item"
done
reply=$("$package/mcc" --version) || fail '无法执行功能包 mcc'
reported=$(printf '%s' "$reply" | /usr/bin/plutil -extract version raw -o - -)
reported_scope=$(printf '%s' "$reply" | /usr/bin/plutil -extract scope raw -o - -)
[ "$reported" = "$version" ] && [ "$reported_scope" = desktop ] || fail 'CLI 版本或通用控制模式与 manifest 不一致'

# 只清理由本进程创建的暂存目录和锁；发布命令链接是安装的最后一步。
staging= link_staging= lock=
cleanup() {
    [ -z "$staging" ] || rm -rf "$staging"
    [ -z "$link_staging" ] || rm -rf "$link_staging"
    [ -z "$lock" ] || rmdir "$lock" 2>/dev/null || :
}
trap cleanup 0
trap 'exit 1' 1 2 15
mkdir -p "$prefix"
prefix=$(CDPATH= cd -P "$prefix" && pwd)
libroot=$prefix/lib/macos-control-cli
destination=$libroot/$version
if [ "$destination" != "$package" ]; then
    case "$destination/" in "$package/"*) fail '不能将安装目标放在功能包内部，避免递归复制' ;; esac
fi
ensure_directory() {
    [ ! -L "$1" ] || fail "拒绝通过符号链接写入安装目录：$1"
    if [ -e "$1" ]; then [ -d "$1" ] || fail "安装路径不是目录：$1"; else mkdir "$1"; fi
}
ensure_directory "$prefix/lib"
ensure_directory "$libroot"
ensure_directory "$prefix/bin"
bindir=$prefix/bin
mkdir "$libroot/.install-lock" 2>/dev/null || fail '此安装前缀已有安装任务或残留锁，请核对后再试'
lock=$libroot/.install-lock
check_command() {
    if [ -L "$bindir/mcc" ]; then
        [ ! -d "$bindir/mcc" ] || fail '已有 mcc 链接指向目录，拒绝将新命令移入该目录'
        old=$(readlink "$bindir/mcc")
        case "$old" in
            "$libroot/"*/mcc) old_version=${old#"$libroot/"}; old_version=${old_version%/mcc}; safe_version "$old_version" || fail '拒绝覆盖无关 mcc 链接' ;;
            *) fail "拒绝覆盖无关 mcc 链接：$bindir/mcc" ;;
        esac
    elif [ -e "$bindir/mcc" ]; then
        fail "拒绝覆盖已有 mcc 文件或目录：$bindir/mcc"
    fi
}
check_command
if [ -e "$destination" ] || [ -L "$destination" ]; then
    [ -d "$destination" ] && [ ! -L "$destination" ] || fail '同版本安装路径不是普通目录'
    diff -qr "$package" "$destination" >/dev/null 2>&1 || fail '同版本已安装但内容不同，拒绝改写；请构建新版本或选择其他 prefix'
    for item in mcc desktop-control copis-chrome copis-chrome-helper; do
        [ -f "$destination/$item" ] && [ ! -L "$destination/$item" ] && [ -x "$destination/$item" ] || fail "已有版本的执行权限或文件类型异常，拒绝激活：$item"
    done
    printf '[mcc] 同版本内容一致，保留已有安装。\n'
else
    staging=$(mktemp -d "$libroot/.install.XXXXXX")
    cp -R "$package/." "$staging/"
    mv "$staging" "$destination"
    staging=
fi
check_command
link_staging=$(mktemp -d "$bindir/.mcc.XXXXXX")
ln -s "$destination/mcc" "$link_staging/mcc"
mv -f "$link_staging/mcc" "$bindir/mcc"
printf '[mcc] 已安装 %s：%s/mcc\n' "$version" "$bindir"
if [ "$(command -v mcc 2>/dev/null || :)" != "$bindir/mcc" ]; then
    printf '当前终端执行以下命令激活（也可自行加入 shell 配置）：\n'
    escaped=$(printf '%s' "$bindir" | sed "s/'/'\\\\''/g")
    printf 'export PATH='"'"'%s'"'"':"$PATH"\n' "$escaped"
fi
printf '使用帮助：%s/mcc --help\n' "$bindir"
