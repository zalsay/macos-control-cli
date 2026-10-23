#!/bin/sh
# 只在临时 HOME/prefix 安装，不修改用户配置；只读帮助及私有 daemon 生命周期，不操作桌面。
set -eu
root=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)
package=${1:?请提供已构建的功能包目录}
python3 - "$root" "$package" "${2:-}" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1]); package = pathlib.Path(sys.argv[2]).resolve()
previous_package = pathlib.Path(sys.argv[3]).resolve() if sys.argv[3] else None
with tempfile.TemporaryDirectory(prefix='mcc-install.', dir='/tmp') as temp:
    work = pathlib.Path(temp); home = work / 'home'; home.mkdir()
    for name in ['.zshrc', '.zprofile', '.bashrc', '.bash_profile']:
        (home / name).write_text('# preserve user settings\n')
    configs = {p.name:p.read_bytes() for p in home.iterdir()}
    env = dict(os.environ, HOME=str(home), PATH='/usr/bin:/bin:/usr/sbin:/sbin', COPIS_DESKTOP_RUNTIME_DIR=str(work/'runtime'))
    env.pop('COPIS_DESKTOP_HELPER', None); env.pop('COPIS_CHROME_HELPER', None)
    installer = root / 'install.sh'
    version = json.loads((package/'module.json').read_text())['version']
    def install(args, ok=True, script=installer):
        p = subprocess.run(['sh',str(script),*map(str,args)],env=env,text=True,capture_output=True,timeout=60)
        assert p.returncode == 0 if ok else p.returncode != 0, (p.returncode,p.stdout,p.stderr)
        return p
    def run(executable,*args):
        p = subprocess.run([str(executable),*map(str,args)],env=env,text=True,capture_output=True,timeout=20)
        assert p.returncode == 0, (p.stdout,p.stderr)
        return p.stdout
    install(['--help'])
    assert not (home/'.local').exists(), '帮助不能安装或创建默认目录'
    install(['--prefix','relative'],False)
    install(['--prefix',str(work/'bad')+'\nline'],False)
    prefix = work / "prefix with spaces ' $literal"
    args = ['--prefix',prefix,'--package',package]
    result = install(args)
    activation = next(line for line in result.stdout.splitlines() if line.startswith('export PATH='))
    activated = subprocess.run(['sh','-c',activation+'; mcc --version'],env=env,text=True,capture_output=True,timeout=10)
    assert activated.returncode==0 and json.loads(activated.stdout)['scope']=='desktop', (activation,activated.stderr)
    link = prefix/'bin/mcc'; payload = prefix/'lib/macos-control-cli'/version
    assert link.is_symlink() and link.resolve() == (payload/'mcc').resolve()
    assert (payload/'copis-chrome-helper').is_file() and (payload/'assets/copis-logo.png').is_file()
    assert (payload/'source/install.sh').is_file()
    help_text = run(link,'--help')
    assert help_text.startswith('mcc —') and 'mcc permissions' in help_text and 'mcc daemon stop' in help_text
    value = json.loads(run(link,'--version'))
    assert value['version']==version and value['scope']=='desktop'
    assert not (work/'runtime').exists(), '帮助和版本不能启动 daemon'
    original = (payload/'mcc').stat()
    install(args)
    assert (payload/'mcc').stat().st_ino == original.st_ino, '重复安装不得改写正在运行的同版本产物'
    executable = payload/'mcc'
    executable.chmod(original.st_mode & 0o666)
    try:
        install(args,False)
        assert not os.access(executable,os.X_OK), '不能悄悄改写已安装版本权限'
    finally:
        executable.chmod(original.st_mode & 0o7777)
    conflict = work/'conflict';(conflict/'bin').mkdir(parents=True)
    other = conflict/'bin/mcc';other.write_text('unrelated command')
    install(['--prefix',conflict,'--package',package],False)
    assert other.read_text()=='unrelated command' and not (conflict/'lib/macos-control-cli'/version).exists()
    other.unlink();other.symlink_to(work/'unrelated-target')
    install(['--prefix',conflict,'--package',package],False)
    assert other.is_symlink() and other.readlink()==work/'unrelated-target'
    other.unlink()
    old_directory = conflict/'lib/macos-control-cli/0.0.0/mcc'
    old_directory.mkdir(parents=True)
    other.symlink_to(old_directory.resolve())
    install(['--prefix',conflict,'--package',package],False)
    assert other.readlink()==old_directory.resolve() and not (old_directory/'mcc').exists(), '不能将新链接移入旧链接指向的目录'
    changed = work/'changed-package';shutil.copytree(package,changed)
    install(['--prefix',changed/'nested','--package',changed],False)
    (changed/'assets/copis-logo.png').write_bytes(b'changed version contents')
    install(['--prefix',prefix,'--package',changed],False)
    assert (payload/'assets/copis-logo.png').read_bytes()==(package/'assets/copis-logo.png').read_bytes()
    metadata=json.loads((changed/'module.json').read_text());metadata['version']='../../escape'
    (changed/'module.json').write_text(json.dumps(metadata))
    install(['--prefix',work/'unsafe','--package',changed],False)
    assert not (work/'escape').exists()
    # 从已解压包安装，无 Rust/Swift/Python 运行时依赖（Python 仅为此测试驱动）。
    install(['--prefix',work/'source-cached'])
    install([],script=package/'install.sh')
    assert (home/'.local/bin/mcc').is_symlink()
    assert json.loads(run(home/'.local/bin/mcc','--version'))['scope']=='desktop'
    assert {p.name:p.read_bytes() for p in home.iterdir() if p.is_file()}==configs
    # Given 已安装上一版，When 安装修复包，Then 使用新版本目录切换链接，且保留旧版原文件。
    if previous_package:
        previous_version = json.loads((previous_package/'module.json').read_text())['version']
        assert previous_version != version, '修复包必须采用新版本号，不能与已安装旧包共用版本号'
        upgrade_prefix = work/'upgrade-prefix'
        install(['--prefix',upgrade_prefix,'--package',previous_package])
        previous_payload = upgrade_prefix/'lib/macos-control-cli'/previous_version
        previous_files = {p.relative_to(previous_payload):p.read_bytes() for p in previous_payload.rglob('*') if p.is_file()}
        previous_link = upgrade_prefix/'bin/mcc'
        assert json.loads(run(previous_link,'--version'))['version']==previous_version
        install(['--prefix',upgrade_prefix,'--package',package])
        assert previous_link.resolve()==(upgrade_prefix/'lib/macos-control-cli'/version/'mcc').resolve()
        assert json.loads(run(previous_link,'--version'))['version']==version
        assert {p.relative_to(previous_payload):p.read_bytes() for p in previous_payload.rglob('*') if p.is_file()}==previous_files, '升级不得改写旧版本内容'
        print('PASS: 从旧版本升级，mcc切换到新版本，旧版本全部文件保留且内容不变')
    # 验证经安装链接启动时能找到相邻原生 helper；不请求权限或采集桌面。
    try:
        assert json.loads(run(link,'daemon','start'))['running'] is True
        assert json.loads(run(link,'daemon','status'))['scope']=='desktop'
    finally:
        run(link,'daemon','stop')
        assert json.loads(run(link,'daemon','status'))['running'] is False
    print('PASS: POSIX安装、空格/引号路径、重复安装、冲突/同版本篡改拒绝、包内独立安装、mcc帮助/模式/helper定位及清理；未操作桌面或修改用户PATH配置')
PY
