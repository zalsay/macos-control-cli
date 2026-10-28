#!/bin/sh
# 本地用户级安装；不联网、不修改 shell 配置、不启动桌面控制。
set -eu
fail() { printf '[mcc] %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
用法：sh install.sh [--prefix <绝对路径>] [--package <功能包目录>]

默认：~/.local/lib/macos-control-cli/<version>/ 保留归档，~/Applications/MCC/ 为真实运行目录，~/.local/bin/mcc 提供命令。
源码目录会优先安装已构建产物；没有产物时调用现有 build.sh（需要 Rust/Swift）。
已解压功能包直接安装，无需 Rust、Swift、Python、Node.js 或 sudo。
--prefix   自定义用户级安装前缀，命令位于 <prefix>/bin/mcc，运行目录为 <prefix>/Applications/MCC。
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
regular_tree() {
    [ -d "$1" ] && [ ! -L "$1" ] || return 1
    [ -z "$(find "$1" ! -type f ! -type d -print -quit)" ]
}
regular_tree "$package" || fail '功能包含符号链接或非普通文件'
package=$(CDPATH= cd -P "$package" && pwd)
field_file() { /usr/bin/plutil -extract "$2" raw -o - "$1/module.json"; }
field() { field_file "$package" "$1"; }
[ "$(field name)" = chrome-desktop-cli ] || fail '功能包名称不匹配'
[ "$(field platform)" = darwin ] && [ "$(field arch)" = "$arch" ] || fail '功能包平台或架构不匹配'
version=$(field version); safe_version "$version" || fail '功能包版本无效'
helper=$(field helper) || fail '功能包 helper 字段无效'
case "$helper" in macos-chrome-helper|copis-chrome-helper) ;; *) fail '功能包 helper 名称不在允许列表' ;; esac
for item in module.json mcc desktop-control copis-chrome "$helper" install.sh assets/copis-logo.png LICENSE USAGE.md README.md README.zh-CN.md source/Cargo.toml source/install.sh; do
    [ -f "$package/$item" ] && [ ! -L "$package/$item" ] || fail "功能包不完整或含不支持的链接：$item"
done
for item in assets docs source; do
    [ -d "$package/$item" ] && [ ! -L "$package/$item" ] || fail "功能包目录不完整或含不支持的链接：$item"
done
for item in mcc desktop-control copis-chrome "$helper"; do
    [ -x "$package/$item" ] || fail "文件不可执行：$item"
    /usr/bin/codesign --verify --strict "$package/$item" 2>/dev/null || fail "代码签名校验失败：$item"
done
reply=$("$package/mcc" --version) || fail '无法执行功能包 mcc'
reported=$(printf '%s' "$reply" | /usr/bin/plutil -extract version raw -o - -)
reported_scope=$(printf '%s' "$reply" | /usr/bin/plutil -extract scope raw -o - -)
[ "$reported" = "$version" ] && [ "$reported_scope" = desktop ] || fail 'CLI 版本或通用控制模式与 manifest 不一致'

# The lock covers archive/stable/link decisions and publication. Cleanup only
# removes our own staging; a failed rollback leaves its backup for inspection.
staging= link_staging= stable_staging= backup_dir= backup_version= lock=
stable= destination= published=0 committed=0 link_attempt=0 link_inode= original_link=0
cleanup() {
    # A rename can succeed even if its caller sees an error or a signal. Only
    # replace/remove the precise symlink inode this transaction published.
    if [ "$committed" != 1 ] && [ "$link_attempt" = 1 ] && [ -L "$bindir/mcc" ] &&
       [ "$(/usr/bin/stat -f %i "$bindir/mcc" 2>/dev/null || :)" = "$link_inode" ]; then
        if [ "$original_link" = 1 ]; then
            mv -f "$link_staging/original" "$bindir/mcc" || {
                printf '[mcc] 命令链接恢复失败，原链接仍保留在暂存目录。\n' >&2
                link_staging=
            }
        else
            rm -f "$bindir/mcc" || :
        fi
    fi
    if [ "$committed" != 1 ] && [ "$published" = 1 ] && { [ -e "$stable" ] || [ -L "$stable" ]; }; then
        if regular_tree "$stable" && [ -d "$destination" ] && diff -qr "$stable" "$destination" >/dev/null 2>&1; then
            rm -rf "$stable" || :
        else
            printf '[mcc] 发布目录发生变化，拒绝清理；保留备份供人工恢复。\n' >&2
        fi
    fi
    if [ "$committed" != 1 ] && [ -n "$backup_dir" ] && [ -d "$backup_dir/MCC" ]; then
        if [ ! -e "$stable" ] && [ ! -L "$stable" ]; then
            mv "$backup_dir/MCC" "$stable" || printf '[mcc] 旧运行目录恢复失败，备份仍保留。\n' >&2
        else
            printf '[mcc] 运行目录被占用，备份仍保留。\n' >&2
        fi
    fi
    [ -z "$staging" ] || rm -rf "$staging"
    [ -z "$stable_staging" ] || rm -rf "$stable_staging"
    [ -z "$link_staging" ] || rm -rf "$link_staging"
    if [ -n "$backup_dir" ]; then
        if [ "$committed" = 1 ] && [ -d "$backup_dir/MCC" ] && [ -n "$backup_version" ] &&
           regular_tree "$backup_dir/MCC" && diff -qr "$backup_dir/MCC" "$libroot/$backup_version" >/dev/null 2>&1; then
            rm -rf "$backup_dir/MCC" || :
        fi
        rmdir "$backup_dir" 2>/dev/null || :
    fi
    [ -z "$lock" ] || rmdir "$lock" 2>/dev/null || :
}
trap cleanup 0
trap 'exit 1' 1 2 15
mkdir -p "$prefix"
prefix=$(CDPATH= cd -P "$prefix" && pwd)
home= default_prefix=
if [ -n "${HOME-}" ] && [ -d "$HOME" ]; then
    home=$(CDPATH= cd -P "$HOME" && pwd)
    if [ -d "$home/.local" ]; then default_prefix=$(CDPATH= cd -P "$home/.local" && pwd); else default_prefix=$home/.local; fi
fi
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
if [ "$prefix" = "$default_prefix" ]; then stable_parent=$home/Applications; else stable_parent=$prefix/Applications; fi
ensure_directory "$stable_parent"
stable=$stable_parent/MCC
case "$stable/" in "$package/"*) fail '不能将运行目录放在功能包内部' ;; esac

# A managed archive is a regular, structurally valid signed payload at the
# exact version path. Never trust a link or a manifest path supplied by it.
validate_archive() {
    archive=$1
    expected_version=$2
    regular_tree "$archive" || return 1
    [ -f "$archive/module.json" ] || return 1
    [ "$(field_file "$archive" name 2>/dev/null)" = chrome-desktop-cli ] || return 1
    [ "$(field_file "$archive" platform 2>/dev/null)" = darwin ] || return 1
    [ "$(field_file "$archive" arch 2>/dev/null)" = "$arch" ] || return 1
    [ "$(field_file "$archive" version 2>/dev/null)" = "$expected_version" ] || return 1
    archive_helper=$(field_file "$archive" helper 2>/dev/null) || return 1
    case "$archive_helper" in macos-chrome-helper|copis-chrome-helper) ;; *) return 1 ;; esac
    for archive_item in mcc desktop-control copis-chrome "$archive_helper"; do
        [ -f "$archive/$archive_item" ] && [ ! -L "$archive/$archive_item" ] && [ -x "$archive/$archive_item" ] || return 1
        /usr/bin/codesign --verify --strict "$archive/$archive_item" >/dev/null 2>&1 || return 1
    done
}
stable_version=
if [ -e "$stable" ] || [ -L "$stable" ]; then
    regular_tree "$stable" || fail '稳定运行目录不是受支持的普通目录'
    stable_version=$(field_file "$stable" version 2>/dev/null) || fail '稳定运行目录 manifest 无效'
    safe_version "$stable_version" || fail '稳定运行目录版本无效'
    validate_archive "$libroot/$stable_version" "$stable_version" || fail '稳定运行目录缺少受管理的版本归档'
    diff -qr "$stable" "$libroot/$stable_version" >/dev/null 2>&1 || fail '稳定运行目录内容与归档不一致，拒绝覆盖'
    for item in mcc desktop-control copis-chrome "$archive_helper"; do
        [ -x "$stable/$item" ] || fail '稳定运行目录执行权限异常'
    done
fi
old_base=
check_command() {
    if [ -L "$bindir/mcc" ]; then
        [ ! -d "$bindir/mcc" ] || fail '已有 mcc 链接指向目录，拒绝覆盖'
        old=$(readlink "$bindir/mcc")
        case "$old" in
            "$libroot/"*/mcc)
                old_version=${old#"$libroot/"}; old_version=${old_version%/mcc}
                safe_version "$old_version" || fail '拒绝覆盖无关 mcc 链接'
                validate_archive "$libroot/$old_version" "$old_version" || fail '旧命令链接未指向有效受管理归档'
                old_base=$libroot/$old_version ;;
            "$stable/mcc")
                [ -n "$stable_version" ] || fail '稳定命令链接没有有效受管理目标'
                old_base=$stable ;;
            *) fail "拒绝覆盖无关 mcc 链接：$bindir/mcc" ;;
        esac
    elif [ -e "$bindir/mcc" ]; then
        fail "拒绝覆盖已有 mcc 文件或目录：$bindir/mcc"
    fi
}
check_command
if [ -e "$destination" ] || [ -L "$destination" ]; then
    validate_archive "$destination" "$version" || fail '同版本安装路径不是有效受管理归档'
    diff -qr "$package" "$destination" >/dev/null 2>&1 || fail '同版本已安装但内容不同，拒绝改写；请构建新版本或选择其他 prefix'
    printf '[mcc] 同版本内容一致，保留已有归档。\n'
else
    staging=$(mktemp -d "$libroot/.install.XXXXXX")
    cp -R "$package/." "$staging/"
    mv "$staging" "$destination"
    staging=
fi
check_command
# Idempotent activation keeps the actual stable inode and current link intact.
if [ "$stable_version" = "$version" ] && [ -L "$bindir/mcc" ] && [ "$(readlink "$bindir/mcc")" = "$stable/mcc" ]; then
    committed=1
else
    # `comm` is the exact executable path, not a substring of argv. Include the
    # entry link as well as canonical managed payload paths, without killing.
    commands=$(ps -ww -axo comm=) || fail '无法检查正在运行的本地进程'
    active_archive=
    [ -z "$stable_version" ] || active_archive=$libroot/$stable_version
    if printf '%s\n' "$commands" | ( while IFS= read -r command; do
        case "$command" in /*) ;; *) continue ;; esac
        case "${command##*/}" in mcc|macos-chrome-helper|copis-chrome-helper|desktop-control|copis-chrome) ;; *) continue ;; esac
        resolved=$(/bin/realpath "$command" 2>/dev/null || :)
        if [ "$command" = "$bindir/mcc" ] || [ "$resolved" = "$bindir/mcc" ]; then exit 0; fi
        for base in "$stable" "$old_base" "$active_archive"; do
            [ -n "$base" ] || continue
            for item in mcc macos-chrome-helper copis-chrome-helper desktop-control copis-chrome; do
                if [ "$command" = "$base/$item" ] || [ "$resolved" = "$base/$item" ]; then exit 0; fi
            done
        done
    done
    exit 1 ); then
        fail '检测到当前管理版本正在运行；请先由操作者停止，未自动终止'
    fi
    link_staging=$(mktemp -d "$bindir/.mcc.XXXXXX")
    ln -s "$stable/mcc" "$link_staging/mcc"
    if [ "$stable_version" != "$version" ]; then
        stable_staging=$(mktemp -d "$stable_parent/.mcc-stage.XXXXXX")
        cp -R "$destination/." "$stable_staging/"
        regular_tree "$stable_staging" && diff -qr "$stable_staging" "$destination" >/dev/null 2>&1 || fail '运行目录暂存校验失败'
        if [ -n "$stable_version" ]; then
            backup_dir=$(mktemp -d "$stable_parent/.mcc-backup.XXXXXX")
            backup_version=$stable_version
            mv "$stable" "$backup_dir/MCC"
        fi
        published=1
        mv "$stable_staging" "$stable"
        stable_staging=
    fi
    check_command
    if [ -L "$bindir/mcc" ]; then
        ln -s "$(readlink "$bindir/mcc")" "$link_staging/original"
        original_link=1
    fi
    link_inode=$(/usr/bin/stat -f %i "$link_staging/mcc") || fail '无法核验暂存命令链接'
    link_attempt=1
    mv -f "$link_staging/mcc" "$bindir/mcc"
    committed=1
fi
printf '[mcc] 已安装 %s：%s/mcc（运行目录 %s）\n' "$version" "$bindir" "$stable"
if [ "$(command -v mcc 2>/dev/null || :)" != "$bindir/mcc" ]; then
    printf '当前终端执行以下命令激活（也可自行加入 shell 配置）：\n'
    escaped=$(printf '%s' "$bindir" | sed "s/'/'\\\\''/g")
    printf 'export PATH='"'"'%s'"'"':"$PATH"\n' "$escaped"
fi
printf '使用帮助：%s/mcc --help\n' "$bindir"
