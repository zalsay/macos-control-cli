#!/bin/bash
# 显式桌面回归：独立 Chrome 配置、本机无上传页面和测试文件；不查看截图、不操作用户窗口。
set -euo pipefail
if [[ "$(uname -s)" != Darwin || $# -lt 1 || $# -gt 2 || ( $# == 2 && "$2" != "--execution-control" ) ]]; then
  echo '用法：bash tests/file-dialog-smoke.sh <copis-chrome绝对路径> [--execution-control]' >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d /tmp/copis-file-dialog-smoke.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
swiftc -O -warnings-as-errors "$root/tests/file-dialog-fixture/main.swift" -o "$scratch/fixture-ax"
/usr/bin/python3 - "$1" "$scratch" "${2:-file-dialog}" <<'PY'
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

cli = str(Path(sys.argv[1]).resolve(strict=True))
scratch = Path(sys.argv[2])
execution_mode = sys.argv[3] == '--execution-control'
chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
if not Path(chrome).is_file():
    raise SystemExit('找不到 Chrome 正式版')
fixture = b'''<!doctype html><meta charset="utf-8"><title>CopisFileChooserFixture</title>
<button id="pick">Copis open test picker</button><input id="file" type="file" accept=".txt" hidden>
<script>pick.onclick=()=>{file.value='';document.title='CopisFileChooserFixture';file.click()};file.onchange=()=>{document.title='CopisFileChosen:'+file.files[0].name}</script>'''
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Security-Policy', "connect-src 'none'; form-action 'none'")
        self.end_headers()
        self.wfile.write(fixture)
    def do_POST(self):
        self.send_error(405)
    def log_message(self, *_):
        pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
test_dir = scratch / '中文 test folder'
test_dir.mkdir()
test_file = test_dir / 'copis-test.txt'
test_file.write_text('仅用于本机文件选择回归；无上传。', encoding='utf-8')
env = dict(os.environ, COPIS_CHROME_RUNTIME_DIR=str(scratch / 'runtime'))
def call(*args, error=None, runtime_env=None):
    completed = subprocess.run([cli, *args], env=runtime_env or env, capture_output=True, text=True, timeout=30)
    result = json.loads(completed.stdout)
    if error:
        assert not result['ok'] and result['error']['code'] == error, result
    else:
        assert completed.returncode == 0 and result['ok'], result
    return result
previous_pid = subprocess.check_output([str(scratch / 'fixture-ax'), '--front-pid'], text=True).strip()
assert int(previous_pid) > 0
owned = None
owned_daemon = None
window = None
cold_env = dict(env, COPIS_CHROME_RUNTIME_DIR=str(scratch / 'cold-runtime'))
try:
    owned = subprocess.Popen([chrome, '--user-data-dir=' + str(scratch / 'profile'),
        '--no-first-run', '--no-default-browser-check', '--disable-sync', '--disable-background-networking',
        '--force-renderer-accessibility', '--window-size=1000,800', f'http://127.0.0.1:{server.server_port}/'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if execution_mode:
        owned_daemon = subprocess.Popen([cli, 'daemon', 'run'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ready = time.monotonic() + 5
        while not (scratch / 'runtime' / 'daemon.sock').exists():
            assert owned_daemon.poll() is None and time.monotonic() < ready, '隔离 daemon 未启动'
            time.sleep(0.02)
    deadline = time.monotonic() + 12
    window = None
    while time.monotonic() < deadline:
        window = next((w for w in call('windows')['windows'] if w['pid'] == owned.pid and 'CopisFileChooserFixture' in w['title']), None)
        if window:
            break
        time.sleep(0.1)
    assert window, '没有找到独立测试窗口'
    connection = call('connect', '--window', str(window['windowId']))['connectionId']
    if execution_mode:
        subprocess.run([str(scratch / 'fixture-ax'), str(owned.pid), str(window['windowId']), 'activate'], check=True, timeout=8)
        observed = call('observe', '--connection', connection)
        frame = observed['frameId']
        children = subprocess.check_output(['pgrep', '-P', str(owned_daemon.pid)], text=True).split()
        helpers = [int(child) for child in children if Path(subprocess.check_output(['ps', '-p', child, '-o', 'comm='], text=True).strip()).name == 'copis-chrome-helper']
        assert len(helpers) == 1, '不能唯一确认隔离 helper'
        helper_pid = helpers[0]
        def hud(action):
            subprocess.run([str(scratch / 'fixture-ax'), str(owned.pid), str(window['windowId']), action + ':' + str(helper_pid)], check=True, timeout=8)
        # 首次动作在原生层等待完整三秒，无需点击执行；倒计时内可移动鼠标。
        first_started = time.monotonic()
        first_input = subprocess.Popen([cli, 'press', '--connection', connection, '--frame', frame, '--key', 'Tab'],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        hud('control-countdown')
        assert first_input.poll() is None, '倒计时尚未结束就完成输入'
        hud('foreign-pointer')
        first_stdout, first_stderr = first_input.communicate(timeout=30)
        first_result = json.loads(first_stdout)
        assert first_input.returncode == 0 and first_result['ok'] and first_result['sent'], (first_result, first_stderr)
        assert time.monotonic() - first_started >= 3, '首次接管不足三秒'
        # 只点击自建空白测试页中心；验证 AI 自己的鼠标事件不会触发接管，不读取截图像素。
        call('click', '--connection', connection, '--frame', frame,
            '--x', str(observed['width'] // 2), '--y', str(observed['height'] // 2))
        def paused_input():
            result = call('press', '--connection', connection, '--frame', frame, '--key', 'ArrowDown', error='FOCUS_LOST')
            assert result['error'].get('reason') == 'USER_PAUSED', result
            assert call('status')['connected']
        hud('pause-control')
        paused_input()
        call('observe', '--connection', connection)
        background = subprocess.run([str(scratch / 'fixture-ax'), str(owned.pid), str(window['windowId']), 'background:' + previous_pid], check=True, capture_output=True, text=True, timeout=5)
        paused_input()
        assert subprocess.check_output([str(scratch / 'fixture-ax'), '--front-pid'], text=True).strip() == previous_pid, '暂停输入抢回了前台'
        hud('execute-control')
        hud('control-countdown')
        cancelled_input = subprocess.Popen([cli, 'press', '--connection', connection, '--frame', frame, '--key', 'Tab'],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        hud('pause-control')
        cancelled_stdout, _ = cancelled_input.communicate(timeout=8)
        cancelled_result = json.loads(cancelled_stdout)
        assert not cancelled_result['ok'] and cancelled_result['error'].get('reason') == 'USER_PAUSED', cancelled_result
        time.sleep(3.1)
        hud('control-paused')
        paused_input()
        hud('execute-control')
        call('press', '--connection', connection, '--frame', frame, '--key', 'Tab')
        hud('foreign-pointer')
        time.sleep(0.15)
        hud('control-paused')
        paused_input()
        call('observe', '--connection', connection)
        hud('execute-control')
        call('press', '--connection', connection, '--frame', frame, '--key', 'Tab')
        # 运行状态下真实切回原应用，也应自动暂停，且新输入不能抢回 Chrome。
        subprocess.run([str(scratch / 'fixture-ax'), str(owned.pid), str(window['windowId']), 'background:' + previous_pid],
            check=True, capture_output=True, text=True, timeout=5)
        hud('control-paused')
        paused_input()
        hud('execute-control')
        hud('control-countdown')
        hud('close-control')
        assert call('status')['connected'], '关闭控制条不应断开连接'
        call('observe', '--connection', connection)
        hud('control-closed')
        time.sleep(3.1)
        hud('control-closed')
        # 新输入只重新显示暂停状态，不能因关闭后重试而恢复输入。
        paused_input()
        hud('control-paused')
        hud('execute-control')
        call('press', '--connection', connection, '--frame', frame, '--key', 'Tab')
        call('disconnect', '--connection', connection)
        time.sleep(0.1)
        hud('control-closed')
        print('PASS: 右上关闭先暂停后隐藏、Observe不复活、旧倒计时不复活、连接保留、首次三秒自动接管、倒计时鼠标移动不暂停、倒计时取消不复活、继续后三秒恢复、真实 CLI/原生按钮暂停与执行、外部鼠标自动接管、暂停不抢前台、Observe继续、连接/帧复用、断开清理；无截图分析')
    else:
        call('select-file', '--connection', 'wrong-connection', '--path', str(test_file), error='CONNECTION_INVALID')
        call('select-file', '--connection', connection, '--path', str(scratch / 'missing.txt'), error='FILE_NOT_READABLE')
        call('select-file', '--connection', connection, '--path', str(test_file), error='FILE_DIALOG_NOT_FOUND')
        assert call('status')['connected'], '参数或对话框错误不应吊销连接'
        # 前置拒绝测试已启动输入控制；隔离正常选择场景，避免 fixture 激活被识别为用户切窗。
        call('disconnect', '--connection', connection)
        connection = call('connect', '--window', str(window['windowId']))['connectionId']
        subprocess.run([str(scratch / 'fixture-ax'), str(owned.pid), str(window['windowId']), 'open'], check=True, timeout=8)
        selected = call('select-file', '--connection', connection, '--path', str(test_file))
        assert selected['connectionId'] == connection and selected['selected'] and selected['dialogClosed'], selected
        subprocess.run([str(scratch / 'fixture-ax'), str(owned.pid), str(window['windowId']), 'selected'], check=True, timeout=8)
        assert call('status')['connected'], '选完文件应保留原连接'
        call('disconnect', '--connection', connection)
        # Given Chrome 在后台且新的 Helper 尚未查询 AX，Then 专用输入能激活原应用后精确定位面板。
        cold_connection = call('connect', '--window', str(window['windowId']), runtime_env=cold_env)['connectionId']
        subprocess.run([str(scratch / 'fixture-ax'), str(owned.pid), str(window['windowId']), 'open'], check=True, timeout=8)
        background = subprocess.run([str(scratch / 'fixture-ax'), str(owned.pid), str(window['windowId']), 'background:' + previous_pid],
            check=True, capture_output=True, text=True, timeout=5)
        assert background.stdout.strip() == 'READY: FIXTURE_CHROME_IS_BACKGROUND'
        cold_selected = call('select-file', '--connection', cold_connection, '--path', str(test_file), runtime_env=cold_env)
        assert cold_selected['selected'] and cold_selected['dialogClosed']
        subprocess.run([str(scratch / 'fixture-ax'), str(owned.pid), str(window['windowId']), 'selected'], check=True, timeout=8)
        call('disconnect', '--connection', cold_connection, runtime_env=cold_env)
        print('PASS: Chrome 明确在后台、独立冷 Helper 首次 AX 查询的真实文件选择回归')
        print('PASS: CLI 真实文件选择 BDD；无 frame、中文空格路径、错误连接/文件/未打开面板拒绝且可恢复；隔离 fixture 无上传')
finally:
    stop_failed = False
    try:
        for private_env in [env, cold_env]:
            try:
                call('daemon', 'stop', runtime_env=private_env)
            except (AssertionError, OSError, subprocess.TimeoutExpired, ValueError):
                stop_failed = True
    finally:
        if owned_daemon:
            try:
                owned_daemon.wait(timeout=3)
            except subprocess.TimeoutExpired:
                owned_daemon.terminate()
                owned_daemon.wait(timeout=3)
        if owned:
            if owned.poll() is None and window:
                try:
                    subprocess.run([str(scratch / 'fixture-ax'), str(owned.pid), str(window['windowId']), 'background:' + previous_pid],
                        capture_output=True, timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    pass
            owned.terminate()
            try:
                owned.wait(timeout=5)
            except subprocess.TimeoutExpired:
                owned.kill()
                owned.wait(timeout=3)
        server.shutdown()
        server.server_close()
    if stop_failed:
        raise RuntimeError('测试私有 runtime 停止未确认')
PY
