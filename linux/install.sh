#!/bin/sh
# User-level installation only. Does not start MCC, Firefox or a display server.
set -eu
fail() { printf '[mcc-linux] %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Usage: sh install.sh [--prefix /absolute/path] [--package /absolute/package]
Ubuntu 22.04 Xorg desktop; install as the logged-in user, without sudo.
Default: ~/.local/lib/mcc-linux-x11/<version>, command ~/.local/bin/mcc.
Source installation builds via build.sh if the package is missing (Rust 1.89+).
An unpacked package needs Python 3 and normal Ubuntu desktop dependencies.
Existing unrelated mcc commands and different contents at the same version are preserved.
Installation does not change PATH, Firefox profiles, session settings or services.
HELP
}
prefix= package=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --prefix|--package)
            [ "$#" -ge 2 ] || fail "$1 requires a value"
            if [ "$1" = --prefix ]; then prefix=$2; else package=$2; fi
            [ -n "$2" ] || fail 'Empty argument'
            shift 2 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done
[ "$(uname -s)" = Linux ] || fail 'Run the Linux installer on Linux'
[ "$(id -u)" != 0 ] || fail 'Run as the logged-in user, without sudo'
prefix=${prefix:-$HOME/.local}
case "$prefix" in /*) ;; *) fail '--prefix must be absolute' ;; esac
case "$prefix" in /|*:*) fail 'Invalid prefix' ;; esac
root=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
if [ -z "$package" ]; then
    if [ -f "$root/module.json" ]; then
        package=$root
    else
        [ -f "$root/../Cargo.toml" ] || fail 'Use --package for an unpacked package'
        root=$(CDPATH= cd -P "$root/.." && pwd)
        version=$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$root/Cargo.toml" | head -n 1)
        case $(uname -m) in aarch64) arch=arm64 ;; x86_64) arch=x64 ;; *) fail 'Unsupported architecture' ;; esac
        package=$root/dist/mcc-$version-linux-$arch
        [ -f "$package/module.json" ] || bash "$root/build.sh"
    fi
fi
python3 - "$package" "$prefix" <<'PY'
import filecmp, json, os, pathlib, re, shutil, subprocess, sys, tempfile
source=pathlib.Path(sys.argv[1]); prefix=pathlib.Path(sys.argv[2])
def fail(message): raise SystemExit('[mcc-linux] '+message)
if not source.is_absolute(): fail('--package must be absolute')
if any(ord(c)<32 or ord(c)==127 for c in str(prefix)): fail('Invalid prefix')
if source.is_symlink() or not source.is_dir(): fail('Invalid package directory')
for p in source.rglob('*'):
    if p.is_symlink() or not (p.is_file() or p.is_dir()): fail('Package contains unsupported links or special files')
manifest=json.loads((source/'module.json').read_text())
version=manifest.get('version','')
arch={'aarch64':'arm64','x86_64':'x64'}.get(os.uname().machine)
if not re.fullmatch(r'[0-9][0-9A-Za-z.+-]{0,63}',version) or '..' in version: fail('Invalid version')
if (manifest.get('name'),manifest.get('platform'),manifest.get('arch'),manifest.get('helper'))!=('mcc-linux-x11','linux',arch,'libexec/mcc-linux-helper'): fail('Package platform/architecture mismatch')
for name in ['mcc','libexec/mcc','libexec/mcc-linux-helper','install.sh','LICENSE']:
    if not (source/name).is_file(): fail('Missing package file: '+name)
for name in ['mcc','libexec/mcc','libexec/mcc-linux-helper']:
    if not os.access(source/name,os.X_OK): fail('Package file is not executable: '+name)
reply=json.loads(subprocess.check_output([str(source/'libexec/mcc'),'--version'],text=True))
if reply.get('version')!=version or reply.get('scope')!='desktop': fail('CLI version/scope mismatch')
store=prefix/'lib/mcc-linux-x11'; bindir=prefix/'bin'
# Refuse symlinked publication directories; never replace an unrelated command.
for directory in [prefix,prefix/'lib',store,bindir]:
    if directory.is_symlink(): fail('Installation directory cannot be a symlink: '+str(directory))
    directory.mkdir(parents=True,exist_ok=True)
    if directory.stat().st_uid!=os.getuid(): fail('Installation directory is not owned by this user')
lock=store/'.install-lock'
try: lock.mkdir(mode=0o700)
except FileExistsError: fail('Installation is already active; inspect the lock before retrying')
staging=None
try:
    destination=store/version; command=bindir/'mcc'
    if os.path.lexists(command):
        if not command.is_symlink(): fail('An unrelated mcc command already exists')
        try: command.resolve().relative_to(store.resolve())
        except ValueError: fail('An unrelated mcc command already exists')
    if destination.is_symlink(): fail('Version directory cannot be a symlink')
    if destination.exists():
        if not destination.is_dir(): fail('Version path is not a directory')
        for p in destination.rglob('*'):
            if p.is_symlink() or not (p.is_file() or p.is_dir()): fail('Installed version contains unsupported links or special files')
        def identical(a,b):
            comparison=filecmp.dircmp(a,b)
            return not comparison.left_only and not comparison.right_only and not comparison.funny_files and all(filecmp.cmp(a/n,b/n,shallow=False) for n in comparison.common_files) and all(identical(a/n,b/n) for n in comparison.common_dirs)
        if not identical(source,destination): fail('Different package contents already exist at this version; preserve them and use a new version/prefix')
    else:
        staging=pathlib.Path(tempfile.mkdtemp(prefix='.install-',dir=store))
        shutil.copytree(source,staging/'package')
        os.rename(staging/'package',destination)
    link=bindir/('.mcc-install-'+str(os.getpid()))
    try:
        link.symlink_to(destination/'mcc'); os.replace(link,command)
    finally:
        if link.is_symlink(): link.unlink()
    print('Installed:',command)
    print('Desktop remains unchanged. Run mcc permissions from an Ubuntu on Xorg terminal.')
finally:
    if staging is not None: shutil.rmtree(staging)
    lock.rmdir()
PY
