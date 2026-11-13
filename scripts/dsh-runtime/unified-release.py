#!/usr/bin/env python3
"""Build and stage a local testing candidate, then update the fixed release paths."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import threading
import time
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
spec = importlib.util.spec_from_file_location('package_release', HERE / 'package-release.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)
NAMES = ('Safarier AI.app', 'candidate-sha256.json', 'release-current.json')
MARKER = '.unified-transaction'
INSTALL_MARKER = '.safarier-install-transaction'
APP_NAME = 'Safarier AI.app'

class Progress:
    """Report completed phases, never an estimate of elapsed work."""
    def __init__(self, total, stream=None, interval=5):
        self.total = total
        self.completed = 0
        self.stream = stream if stream is not None else sys.stderr
        self.interval = interval

    def _line(self, message):
        width = 20
        filled = self.completed * width // self.total
        bar = '[' + '#' * filled + '-' * (width - filled) + ']'
        print(f'{bar} [{self.completed}/{self.total}] {message}', file=self.stream, flush=True)

    @contextmanager
    def step(self, name):
        self._line(name)
        stopped = threading.Event()
        started = time.monotonic()
        def heartbeat():
            while not stopped.wait(self.interval):
                self._line(f'{name}：运行中 ({int(time.monotonic() - started)}秒)')
        worker = None
        if self.stream.isatty():
            worker = threading.Thread(target=heartbeat, daemon=True)
            worker.start()
        try:
            yield
        except BaseException:
            stopped.set()
            if worker: worker.join()
            self._line(f'{name}：失败')
            raise
        else:
            stopped.set()
            if worker: worker.join()
            self.completed += 1
            if self.completed == self.total:
                self._line('完成')

@contextmanager
def writer_lock(destination):
    path = destination / '.unified-release.lock'
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise RuntimeError('另一统一构建正在运行，无法取得锁')
        yield
    finally:
        os.close(fd)

def reject_residual(destination):
    marker = destination / MARKER
    if marker.exists() or marker.is_symlink():
        raise RuntimeError(f'发现未完成事务 {marker}；停止并检查其中的 RECOVERY.txt 后手动恢复')

def publish(destination, stage, backup_name=None):
    """Caller holds writer_lock. Preserve transaction evidence on uncertain rollback."""
    reject_residual(destination)
    backup_name = backup_name or ('.unified-release-backup-' + uuid.uuid4().hex + '.noindex')
    backup = destination / backup_name
    if backup.exists() or backup.is_symlink(): raise FileExistsError(backup)
    for name in NAMES:
        old, new = destination / name, stage / name
        if old.is_symlink() or not old.exists() or new.is_symlink() or not new.exists():
            raise RuntimeError(f'固定路径或候选缺失，或为符号链接: {name}')
    marker = destination / MARKER
    prepared = stage / ('.transaction-prepared-' + uuid.uuid4().hex)
    prepared.mkdir(mode=0o700)
    (prepared / 'RECOVERY.txt').write_text(
        '更新未完成。请先确认没有统一构建进程；不要启动或覆盖固定包。\n'
        f'旧路径备份在 {marker}/previous/，新路径暂存于 {stage}。\n'
        '逐项检查 previous、固定目录和 staging，恢复全部旧版本或完成全部新版本，'
        '核验 App 签名、pins 和 release-current 一致后，手动移走此事务目录。\n')
    (prepared / 'previous').mkdir()
    os.rename(prepared, marker)
    previous = marker / 'previous'
    saved, installed = [], []
    try:
        for name in NAMES:
            os.rename(destination / name, previous / name)
            saved.append(name)
            os.rename(stage / name, destination / name)
            installed.append(name)
        os.rename(marker, backup)
        return backup / 'previous'
    except BaseException:
        try:
            for name in reversed(installed):
                os.rename(destination / name, stage / name)
            for name in reversed(saved):
                os.rename(previous / name, destination / name)
            os.rename(marker, backup)
        except BaseException as rollback_error:
            raise RuntimeError(f'回滚未完成，保留 {marker}；请按 RECOVERY.txt 恢复: {rollback_error}') from rollback_error
        raise

def running_target_processes(target):
    """Point-in-time observation only; does not prevent a subsequent launch."""
    result = subprocess.run(['/bin/ps', '-ww', '-axo', 'pid=,comm='], check=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    root = os.path.realpath(target) + '/'
    found = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit():
            raise RuntimeError('无法解析进程列表，停止安装')
        if os.path.realpath(fields[1]).startswith(root): found.append(fields[0])
    return found

def install_candidate(fixed, pins, applications):
    """Copy and install under one directory; caller must not launch the target."""
    applications = Path(applications)
    if applications.is_symlink() or not applications.is_dir():
        raise RuntimeError(f'安装目录不存在或为符号链接: {applications}')
    info = applications.stat()
    if info.st_uid != os.getuid() or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise RuntimeError(f'安装目录所有者或权限不安全: {applications}')
    target = applications / APP_NAME
    marker = applications / INSTALL_MARKER
    with writer_lock(applications):
        if marker.exists() or marker.is_symlink():
            raise RuntimeError(f'发现未完成安装事务 {marker}；请按 RECOVERY.txt 恢复')
        if target.is_symlink() or (target.exists() and not target.is_dir()):
            raise RuntimeError(f'安装目标为符号链接或不是目录: {target}')
        if running_target_processes(target):
            raise RuntimeError(f'安装目标 App 或 Browser 正在运行: {target}；请退出后重新执行')
        prepared = applications / ('.safarier-install-prepared-' + uuid.uuid4().hex)
        prepared.mkdir(mode=0o700)
        (prepared / 'RECOVERY.txt').write_text(
            '安装未完成。先确认没有统一构建或目标 App/Browser 进程，勿启动目标。\n'
            f'目标: {target}\n事务目录: {marker}\n'
            'previous.app 为旧包（首次安装可能不存在），candidate.app 为新包（可能已移到目标）。\n'
            '检查三个位置及签名/pins，恢复旧包或核验新包；保留所需证据后手动移走事务目录。\n'
            'release 固定目录可能已经更新，不能假定它与安装包一致。\n')
        os.rename(prepared, marker)
        candidate, previous = marker / 'candidate.app', marker / 'previous.app'
        saved = installed = False
        try:
            package.check_app(fixed, pins)
            shutil.copytree(fixed, candidate, symlinks=True)
            package.check_app(candidate, pins)
            package.check_app(fixed, pins)
            if running_target_processes(target):
                raise RuntimeError(f'安装目标 App 或 Browser 正在运行: {target}；请退出后重新执行')
            if target.is_symlink() or (target.exists() and not target.is_dir()):
                raise RuntimeError(f'安装目标为符号链接或不是目录: {target}')
            if target.exists():
                os.rename(target, previous); saved = True
            os.rename(candidate, target); installed = True
            package.check_app(target, pins)
            package.check_app(fixed, pins)
            backup = applications / ('.safarier-install-backup-' + uuid.uuid4().hex + '.noindex')
            os.rename(marker, backup)
            return backup / 'previous.app' if saved else None
        except Exception:
            try:
                if installed: os.rename(target, candidate)
                if saved: os.rename(previous, target)
                os.rename(marker, applications / ('.safarier-install-failed-' + uuid.uuid4().hex + '.noindex'))
            except Exception as rollback_error:
                raise RuntimeError(f'安装回滚未完成，保留 {marker}；请按 RECOVERY.txt 恢复: {rollback_error}') from rollback_error
            raise

def verify_swift_anchor(artifact):
    source = ROOT / 'Sources/Safarier/ManagerGUI/DshControlledRuntime.swift'
    text = source.read_text()
    blocks = re.findall(r'static let reviewedAnchor: Anchor\? = Anchor\((.*?)\n    \)', text, re.S)
    if len(blocks) != 1: raise ValueError('Swift reviewedAnchor 不唯一或格式已变化')
    fields = dict(re.findall(r'(imageSHA256|manifestSHA256|nodeSHA256|nodeTeamID): "([A-Za-z0-9]+)"', blocks[0]))
    anchor = package.install.required_anchor()
    if fields.get('imageSHA256') != anchor.image_sha256 or fields.get('manifestSHA256') != anchor.manifest_sha256:
        raise ValueError('Swift 和 Python runtime 锚不一致，需要重新审核')
    manifest = json.loads((artifact / 'manifest.json').read_text())
    nodes = [e for e in manifest['entries'] if e.get('path') == 'node/node' and e.get('type') == 'file']
    if len(nodes) != 1 or nodes[0].get('sha256') != fields.get('nodeSHA256') or not fields.get('nodeTeamID'):
        raise ValueError('Swift Node 锚与 manifest 不一致，需要重新审核')
    return hashlib.sha256(source.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact', type=Path, default=ROOT / 'dist/releases/2026-11-10-unified-dsh-202325/runtime-artifact')
    args = parser.parse_args()
    artifact = args.artifact.absolute()
    destination = ROOT / 'dist/releases'
    progress = Progress(7)
    with writer_lock(destination):
        with progress.step('检查事务及审核后的 runtime'):
            reject_residual(destination)
            anchor_source = verify_swift_anchor(artifact)
            package.verify.verify_artifact(artifact, package.install.required_anchor().hashes)
        with progress.step('构建 testing release'):
            package.build.main('testing', 'release')
            attempt = package.build.ATTEMPT
            layout = package.build.variant_layout('testing')
            app = attempt / layout['app']
            pins = attempt / 'candidate-sha256.json'
        with progress.step('打包候选与 sidecar'):
            unique = datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex
            output = destination / ('unified-testing-' + unique)
            package.package_release(app, artifact, pins, output)
        with progress.step('准备并校验固定路径候选'):
            stage = attempt / 'fixed-release-stage'; stage.mkdir()
            shutil.copytree(output / 'Safarier AI.app', stage / 'Safarier AI.app', symlinks=True)
            shutil.copyfile(pins, stage / 'candidate-sha256.json')
            parsed = package.read_pins(stage / 'candidate-sha256.json')
            package.check_app(stage / 'Safarier AI.app', parsed)
            backup_name = '.unified-release-backup-' + unique + '.noindex'
            metadata = {'updatedAtUTC': datetime.now(timezone.utc).isoformat(), 'sourceBuild': str(attempt),
                'sourceBundle': str(output / 'Safarier AI.app'), 'destination': str(destination / 'Safarier AI.app'),
                'sidecarPackage': str(output), 'sidecarInstructions': str(output / 'INSTALL.txt'),
                'variant': 'testing', 'configuration': 'release', 'pinCount': len(parsed),
                'pinsSHA256': package.build.sha(stage / 'candidate-sha256.json'),
                'pinsTrust': 'candidate consistency evidence, not an independent trust anchor',
                'runtimeImageSHA256': package.install.required_anchor().image_sha256,
                'runtimeManifestSHA256': package.install.required_anchor().manifest_sha256,
                'previousFixedBackup': str(destination / backup_name / 'previous'),
                'guiAcceptance': 'pending', 'cliAcceptance': 'pending',
                'releaseStatus': 'local testing candidate; not notarized or publicly published'}
            (stage / 'release-current.json').write_text(json.dumps(metadata, indent=2) + '\n')
        with progress.step('复核构建后源码和锚'):
            if verify_swift_anchor(artifact) != anchor_source or package.build.source_inventory('testing') != json.loads((attempt / 'source-after.json').read_text()):
                raise RuntimeError('源码在构建或打包后发生变化，停止更新')
        with progress.step('更新固定路径'):
            backup = publish(destination, stage, backup_name)
        print(f'release 固定候选已更新；旧版本备份: {backup}', flush=True)
        print('安装期间请勿启动或操作目标 App；其他路径的 Manager 不会自动关闭。', file=sys.stderr, flush=True)
        try:
            with progress.step('校验并安装固定候选'):
                applications = Path.home() / 'Applications'
                if not applications.exists() and not applications.is_symlink():
                    applications.mkdir(mode=0o700)
                installed_backup = install_candidate(destination / APP_NAME, parsed, applications)
        except Exception as exc:
            raise RuntimeError(f'release 固定候选已更新（旧版本备份: {backup}），但安装未完成: {exc}') from exc
        except BaseException:
            print('release 固定候选已更新；安装被中断，请检查安装事务恢复标记。', file=sys.stderr, flush=True)
            raise
        print(f'固定候选已更新；旧版本备份: {backup}\n安装完成；旧安装包备份: {installed_backup or "无（首次安装）"}\n配套 sidecar: {output}\n请退出其他路径运行的 Manager，然后从 {applications / APP_NAME} 启动，避免唯一路由冲突。\nGUI/CLI 待验收；未启动 App。')

if __name__ == '__main__':
    try: main()
    except Exception as exc:
        print(f'统一构建停止: {type(exc).__name__}: {exc}', file=sys.stderr)
        sys.exit(1)
