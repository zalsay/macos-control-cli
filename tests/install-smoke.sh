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
    metadata = json.loads((package/'module.json').read_text())
    version = metadata['version']
    helper_name = metadata['helper']
    assert helper_name in ('copis-chrome-helper','macos-chrome-helper')
    def install(args, ok=True, script=installer, extra_env=None):
        install_env = dict(env, **(extra_env or {}))
        p = subprocess.run(['sh',str(script),*map(str,args)],env=install_env,text=True,capture_output=True,timeout=60)
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
    nohome_env = dict(env); nohome_env.pop('HOME', None)
    nohome_prefix = work/'no-home'
    nohome = subprocess.run(['sh',str(installer),'--prefix',str(nohome_prefix),'--package',str(package)],env=nohome_env,text=True,capture_output=True,timeout=60)
    assert nohome.returncode == 0, ('explicit prefix without HOME',nohome.stdout,nohome.stderr)
    assert (nohome_prefix/'bin/mcc').resolve() == (nohome_prefix/'Applications/MCC/mcc').resolve()
    prefix = work / "prefix with spaces ' $literal"
    args = ['--prefix',prefix,'--package',package]
    result = install(args)
    activation = next(line for line in result.stdout.splitlines() if line.startswith('export PATH='))
    activated = subprocess.run(['sh','-c',activation+'; mcc --version'],env=env,text=True,capture_output=True,timeout=10)
    assert activated.returncode==0 and json.loads(activated.stdout)['scope']=='desktop', (activation,activated.stderr)
    link = prefix/'bin/mcc'; payload = prefix/'lib/macos-control-cli'/version
    stable = prefix/'Applications/MCC'
    assert link.is_symlink() and link.resolve() == (stable/'mcc').resolve(), 'mcc必须指向真实稳定目录，而非版本归档'
    assert stable.is_dir() and not stable.is_symlink() and (stable/'mcc').is_file() and not (stable/'mcc').is_symlink()
    assert (payload/helper_name).is_file() and (payload/'assets/copis-logo.png').is_file()
    assert (stable/helper_name).is_file() and not (stable/helper_name).is_symlink()
    assert (stable/'assets/copis-logo.png').read_bytes() == (payload/'assets/copis-logo.png').read_bytes()
    assert (payload/'source/install.sh').is_file()
    help_text = run(link,'--help')
    assert help_text.startswith('mcc —') and 'mcc permissions' in help_text and 'mcc daemon stop' in help_text
    value = json.loads(run(link,'--version'))
    assert value['version']==version and value['scope']=='desktop'
    assert not (work/'runtime').exists(), '帮助和版本不能启动 daemon'
    original = (payload/'mcc').stat()
    stable_inode = (stable/'mcc').stat().st_ino
    stable_dir_inode = stable.stat().st_ino
    install(args)
    assert (stable/'mcc').stat().st_ino == stable_inode and stable.stat().st_ino == stable_dir_inode, '重复安装不能替换stable inode'
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
    # Manifest special files must be rejected before invoking plutil, bounded
    # even when no FIFO writer exists. Kill only this test's process group.
    malformed=work/'manifest-fifo';shutil.copytree(package,malformed)
    (malformed/'module.json').unlink();os.mkfifo(malformed/'module.json')
    import signal
    proc=subprocess.Popen(['sh',str(installer),'--prefix',str(work/'manifest-fifo-prefix'),'--package',str(malformed)],
                          env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
    try:
        output,error=proc.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid,signal.SIGKILL);proc.communicate()
        raise AssertionError('FIFO manifest must be rejected before reading, within 3 seconds')
    assert proc.returncode != 0 and '功能包含符号链接或非普通文件' in error and not (work/'manifest-fifo-prefix').exists(), (output,error)
    manifest_link=work/'manifest-link';shutil.copytree(package,manifest_link)
    (manifest_link/'module.json').unlink();(manifest_link/'module.json').symlink_to(package/'module.json')
    install(['--prefix',work/'manifest-link-prefix','--package',manifest_link],False)
    assert not (work/'manifest-link-prefix').exists()
    changed = work/'changed-package';shutil.copytree(package,changed)
    install(['--prefix',changed/'nested','--package',changed],False)
    (changed/'assets/copis-logo.png').write_bytes(b'changed version contents')
    install(['--prefix',prefix,'--package',changed],False)
    assert (payload/'assets/copis-logo.png').read_bytes()==(package/'assets/copis-logo.png').read_bytes()
    metadata=json.loads((changed/'module.json').read_text());metadata['version']='../../escape'
    (changed/'module.json').write_text(json.dumps(metadata))
    install(['--prefix',work/'unsafe','--package',changed],False)
    assert not (work/'escape').exists()
    # Existing stable content must be a verified managed payload, never a link,
    # special file, foreign directory, or a modified copy of the archive.
    foreign = work/'foreign'; foreign.mkdir(); (foreign/'keep').write_text('untouched')
    for kind in ['symlink','fifo','file','directory']:
        bad_prefix=work/('bad-stable-'+kind); parent=bad_prefix/'Applications'; parent.mkdir(parents=True)
        target=parent/'MCC'
        if kind=='symlink': target.symlink_to(foreign, target_is_directory=True)
        elif kind=='fifo': os.mkfifo(target)
        elif kind=='file': target.write_text('unmanaged')
        else: target.mkdir(); (target/'keep').write_text('unmanaged')
        install(['--prefix',bad_prefix,'--package',package],False)
        assert (foreign/'keep').read_text()=='untouched'
        assert not (bad_prefix/'lib/macos-control-cli'/version).exists()
    data=(stable/'assets/copis-logo.png').read_bytes()
    (stable/'assets/copis-logo.png').write_bytes(b'tampered')
    install(args,False)
    assert (stable/'assets/copis-logo.png').read_bytes()==b'tampered'
    (stable/'assets/copis-logo.png').write_bytes(data)
    extra=stable/'unknown-link'; extra.symlink_to(foreign)
    install(args,False)
    assert extra.is_symlink() and (foreign/'keep').read_text()=='untouched'
    extra.unlink()
    fifo=stable/'unknown-fifo';os.mkfifo(fifo)
    install(args,False)
    assert fifo.exists();fifo.unlink()
    invalid_helper=work/'invalid-helper';shutil.copytree(package,invalid_helper)
    invalid_meta=json.loads((invalid_helper/'module.json').read_text())
    invalid_meta['helper']='../outside'
    (invalid_helper/'module.json').write_text(json.dumps(invalid_meta))
    install(['--prefix',work/'bad-helper','--package',invalid_helper],False)
    assert not (work/'bad-helper/Applications/MCC').exists()
    lock=payload.parent/'.install-lock';lock.mkdir()
    inode_before=(stable/'mcc').stat().st_ino; link_before=link.readlink()
    install(args,False)
    assert (stable/'mcc').stat().st_ino==inode_before and link.readlink()==link_before
    lock.rmdir()
    # 从已解压包安装，无 Rust/Swift/Python 运行时依赖（Python 仅为此测试驱动）。
    install(['--prefix',work/'source-cached','--package',package])
    install(['--package',package])
    default_stable = home/'Applications/MCC'
    assert (home/'.local/bin/mcc').is_symlink()
    assert (home/'.local/bin/mcc').resolve() == (default_stable/'mcc').resolve()
    default_inode = (default_stable/'mcc').stat().st_ino
    install(['--prefix',home/'.local/../.local','--package',package])
    assert (default_stable/'mcc').stat().st_ino == default_inode
    assert not (home/'.local/Applications/MCC').exists()
    assert json.loads(run(home/'.local/bin/mcc','--version'))['scope']=='desktop'
    assert {p.name:p.read_bytes() for p in home.iterdir() if p.is_file()}==configs
    # Given 已安装上一版，When 安装修复包，Then 使用新版本目录切换链接，且保留旧版原文件。
    if previous_package:
        previous_version = json.loads((previous_package/'module.json').read_text())['version']
        assert previous_version != version, '修复包必须采用新版本号，不能与已安装旧包共用版本号'
        upgrade_prefix = work/'upgrade-prefix'
        install(['--prefix',upgrade_prefix,'--package',previous_package],script=previous_package/'install.sh')
        previous_payload = upgrade_prefix/'lib/macos-control-cli'/previous_version
        previous_files = {p.relative_to(previous_payload):p.read_bytes() for p in previous_payload.rglob('*') if p.is_file()}
        previous_link = upgrade_prefix/'bin/mcc'
        assert json.loads(run(previous_link,'--version'))['version']==previous_version
        assert previous_link.resolve() == (previous_payload/'mcc').resolve(), '旧installer应先生成归档链接'
        install(['--prefix',upgrade_prefix,'--package',package])
        assert previous_link.resolve()==(upgrade_prefix/'Applications/MCC/mcc').resolve()
        assert json.loads(run(previous_link,'--version'))['version']==version
        assert {p.relative_to(previous_payload):p.read_bytes() for p in previous_payload.rglob('*') if p.is_file()}==previous_files, '升级不得改写旧版本内容'
        # A daemon launched directly from the currently managed archive also
        # blocks replacement, even when bin/mcc now points at stable.
        import time
        archive = upgrade_prefix/'lib/macos-control-cli'/version
        running_env = dict(env, COPIS_DESKTOP_RUNTIME_DIR=str(work/'archive-runtime'),
                           COPIS_DESKTOP_HELPER=str(root/'tests/fixtures/fake-helper.sh'))
        running = subprocess.Popen([str((archive/'mcc').resolve()),'daemon','run'],env=running_env,
                                   stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            deadline=time.monotonic()+8
            while not (work/'archive-runtime/daemon.sock').exists() and running.poll() is None and time.monotonic()<deadline:
                time.sleep(0.02)
            assert (work/'archive-runtime/daemon.sock').exists(), '隔离fake daemon未启动'
            stable_before=(upgrade_prefix/'Applications/MCC/mcc').read_bytes()
            link_before=previous_link.readlink()
            rejected=install(['--prefix',upgrade_prefix,'--package',previous_package],False)
            assert '正在运行' in rejected.stderr
            assert (upgrade_prefix/'Applications/MCC/mcc').read_bytes()==stable_before
            assert previous_link.readlink()==link_before
        finally:
            subprocess.run([str(previous_link),'daemon','stop'],env=running_env,capture_output=True,timeout=10)
            try: running.wait(timeout=10)
            except subprocess.TimeoutExpired: running.kill(); running.wait()
        # Another prefix and a path appearing only in argv must not block us.
        other_runtime=dict(env, COPIS_DESKTOP_RUNTIME_DIR=str(work/'other-runtime'),
                           COPIS_DESKTOP_HELPER=str(root/'tests/fixtures/fake-helper.sh'))
        other_proc=subprocess.Popen([str((stable/'mcc').resolve()),'daemon','run'],env=other_runtime,
                                    stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        argument_proc=subprocess.Popen(['/bin/sh','-c','sleep 20',str(upgrade_prefix/'Applications/MCC/mcc')],
                                       stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            deadline=time.monotonic()+8
            while not (work/'other-runtime/daemon.sock').exists() and other_proc.poll() is None and time.monotonic()<deadline: time.sleep(0.02)
            assert (work/'other-runtime/daemon.sock').exists()
            install(['--prefix',upgrade_prefix,'--package',previous_package])
            install(['--prefix',upgrade_prefix,'--package',package])
        finally:
            subprocess.run([str(link),'daemon','stop'],env=other_runtime,capture_output=True,timeout=10)
            try: other_proc.wait(timeout=10)
            except subprocess.TimeoutExpired: other_proc.kill();other_proc.wait()
            argument_proc.terminate();argument_proc.wait(timeout=10)
        # mv can publish successfully while reporting failure. Roll back only
        # our link, preserving both legacy and already-stable entry states.
        postfaultbin=work/'postfault-bin';postfaultbin.mkdir();postmv=postfaultbin/'mv'
        postmv.write_text('#!/bin/sh\ndest=\nfor arg in "$@"; do dest=$arg; done\nif [ "$dest" = "$MCC_FAULT_DEST" ] && [ ! -e "$MCC_FAULT_MARK" ]; then : > "$MCC_FAULT_MARK"; /bin/mv "$@" || exit $?; exit 1; fi\nexec /bin/mv "$@"\n')
        postmv.chmod(0o755)
        for mode in ('legacy','stable','empty'):
            location=work/('postfail-'+mode)
            if mode=='legacy': install(['--prefix',location,'--package',previous_package],script=previous_package/'install.sh')
            if mode=='stable': install(['--prefix',location,'--package',previous_package])
            entry=location/'bin/mcc'; old_link=entry.readlink() if entry.is_symlink() else None
            old_stable=location/'Applications/MCC'; old_inode=(old_stable/'mcc').stat().st_ino if old_stable.exists() else None
            marker=work/('postfail-mark-'+mode)
            fault_env={'PATH':str(postfaultbin)+':/usr/bin:/bin:/usr/sbin:/sbin','MCC_FAULT_DEST':str(location.resolve()/'bin/mcc'),'MCC_FAULT_MARK':str(marker)}
            install(['--prefix',location,'--package',package],False,extra_env=fault_env)
            assert marker.exists(), mode+' did not reach post-rename failure'
            assert (entry.readlink() if entry.is_symlink() else None)==old_link, mode+' bin link not restored'
            assert ((old_stable/'mcc').stat().st_ino if old_stable.exists() else None)==old_inode, mode+' stable not restored'
        # Fault exactly between the two directory renames, then at link publish.
        stable_upgrade=upgrade_prefix/'Applications/MCC'
        saved_bytes=(stable_upgrade/'mcc').read_bytes(); saved_inode=(stable_upgrade/'mcc').stat().st_ino
        saved_link=previous_link.readlink()
        untouched=upgrade_prefix/'Applications/.mcc-backup-unrelated';untouched.mkdir();(untouched/'keep').write_text('keep')
        faultbin=work/'fault-bin';faultbin.mkdir();mv=faultbin/'mv'
        mv.write_text("#!/bin/sh\ndest=\nfor arg in \"$@\"; do dest=$arg; done\nif [ \"$dest\" = \"$MCC_FAULT_DEST\" ] && [ ! -e \"$MCC_FAULT_MARK\" ]; then : > \"$MCC_FAULT_MARK\"; exit 1; fi\nexec /bin/mv \"$@\"\n")
        mv.chmod(0o755)
        for label,dest in [('stage',stable_upgrade.resolve()),('link',upgrade_prefix.resolve()/'bin/mcc')]:
            marker=work/('fault-'+label)
            fault_env={'PATH':str(faultbin)+':/usr/bin:/bin:/usr/sbin:/sbin',
                       'MCC_FAULT_DEST':str(dest),'MCC_FAULT_MARK':str(marker)}
            install(['--prefix',upgrade_prefix,'--package',previous_package],False,extra_env=fault_env)
            assert marker.exists(), label+' did not reach the intended publish failure'
            assert (stable_upgrade/'mcc').read_bytes()==saved_bytes
            assert (stable_upgrade/'mcc').stat().st_ino==saved_inode
            assert previous_link.readlink()==saved_link
            assert (untouched/'keep').read_text()=='keep'
        assert {p.relative_to(previous_payload):p.read_bytes() for p in previous_payload.rglob('*') if p.is_file()}==previous_files
        # Roll back through the new installer: same stable path, original archive.
        install(['--prefix',upgrade_prefix,'--package',previous_package])
        assert previous_link.resolve()==(stable_upgrade/'mcc').resolve()
        assert json.loads(run(previous_link,'--version'))['version']==previous_version
        assert {p.relative_to(previous_payload):p.read_bytes() for p in previous_payload.rglob('*') if p.is_file()}==previous_files
        install(['--prefix',upgrade_prefix,'--package',package])
        print('PASS: 从旧版本升级，mcc切换到新版本，旧版本全部文件保留且内容不变')
    # Actual packaged helper discovery: no override, no permission request or input.
    env.pop('COPIS_DESKTOP_HELPER', None)
    try:
        assert json.loads(run(link,'daemon','start'))['running'] is True
        assert json.loads(run(link,'daemon','status'))['scope']=='desktop'
        rows = [line.split(None, 2) for line in subprocess.check_output(['ps','-ww','-axo','pid=,ppid=,comm='],text=True).splitlines()]
        assert any(len(row)==3 and pathlib.Path(row[2]).resolve()==(stable/helper_name).resolve() for row in rows), '未发现固定目录中的真实新名helper进程'
    finally:
        run(link,'daemon','stop')
        assert json.loads(run(link,'daemon','status'))['running'] is False
    print('PASS: POSIX安装、空格/引号路径、重复安装、冲突/同版本篡改拒绝、包内独立安装、mcc帮助/模式/helper定位及清理；未操作桌面或修改用户PATH配置')
PY
