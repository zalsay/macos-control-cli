#!/bin/bash
# 独立 Chrome 页面按 AX 屏幕几何点击，读取 DOM 事件验证实际落点，不接触用户页面。
set -euo pipefail
if [[ "$(uname -s)" != Darwin || $# != 1 ]]; then
  echo '用法：bash tests/coordinate-smoke.sh <copis-chrome绝对路径>' >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d /tmp/copis-coordinates.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
swiftc -O -warnings-as-errors "$root/tests/coordinate-fixture/main.swift" -o "$scratch/fixture-ax"
/usr/bin/python3 - "$1" "$scratch" <<'PY'
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
env = dict(os.environ, COPIS_CHROME_RUNTIME_DIR=str(scratch / 'runtime'))
fixture = '''<!doctype html><meta charset="utf-8"><title>CopisCoordinateFixture</title>
<style>body{margin:0}button,input{position:absolute;left:160px;width:240px;height:56px;border:0;border-radius:0;box-sizing:border-box}#top{top:90px;background:#f00}#middle{top:290px;background:#0f0}#bottom{top:490px;background:#00f}</style>
<button id="top">Copis target top</button><input id="middle" aria-label="Copis target middle"><button id="bottom">Copis target bottom</button>
<script>
let movements=0,trusted=true;
document.addEventListener('mousemove',e=>{movements++;trusted=trusted&&e.isTrusted});
document.addEventListener('click',e=>{
 document.title='CopisCoordinateFixture:'+JSON.stringify({target:e.target.id,screenX:e.screenX,screenY:e.screenY,clientX:e.clientX,clientY:e.clientY,movements,trusted,detail:e.detail});
 movements=0;trusted=true;
});
</script>'''.encode()
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
def ax(*args):
    completed = subprocess.run([str(scratch / 'fixture-ax'), *map(str, args)], capture_output=True, text=True, timeout=8)
    assert completed.returncode == 0, completed.stderr
    return json.loads(completed.stdout) if completed.stdout.strip() else None
def call(*args, allow_geometry_change=False, expected_error=None):
    completed = subprocess.run([cli, *map(str, args)], env=env, capture_output=True, text=True, timeout=30)
    result = json.loads(completed.stdout)
    if expected_error:
        assert not result['ok'] and result['error']['code'] == expected_error, result
        return result
    if allow_geometry_change and not result['ok'] and result['error']['code'] == 'FRAME_GEOMETRY_CHANGED':
        return None
    assert completed.returncode == 0 and result['ok'], result
    return result
def observe_fixture_geometry(connection, geometry):
    # AX 调整窗口可能尚在异步生效，只在测试准备阶段重试只读 Observe，不重放输入。
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        observed = call('observe', '--connection', connection, allow_geometry_change=True)
        if observed:
            bounds = observed['bounds']
            if tuple(bounds[k] for k in ['x', 'y', 'width', 'height']) == geometry:
                return observed
        time.sleep(0.05)
    raise AssertionError(('隔离窗口几何未稳定', geometry))
desktop = ax('--desktop')
print('DESKTOP', json.dumps(desktop, ensure_ascii=False))
owned = None
window = None
try:
    owned = subprocess.Popen(['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '--user-data-dir=' + str(scratch / 'profile'), '--no-first-run', '--no-default-browser-check',
        '--disable-sync', '--disable-background-networking', '--force-renderer-accessibility',
        '--window-size=1000,800', f'http://127.0.0.1:{server.server_port}/'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        window = next((w for w in call('windows')['windows'] if w['pid'] == owned.pid and 'CopisCoordinateFixture' in w['title']), None)
        if window:
            break
        time.sleep(0.1)
    assert window, '没有找到隔离坐标测试窗口'
    connection = call('connect', '--window', window['windowId'])['connectionId']
    tested_geometries = 0
    scale = desktop['screens'][0]['scale']
    native_width, native_height = min(1000, int(1600 / scale)), min(800, int(1600 / scale))
    for index, geometry in enumerate([(48, 150, native_width, native_height), (180, 44, native_width, native_height), (120, 80, 2000, 1100)]):
        if geometry[0] + geometry[2] > desktop['screens'][0]['width'] or geometry[1] + geometry[3] > desktop['screens'][0]['height']:
            print('SKIP: 主屏逻辑区域不足以容纳几何', geometry)
            continue
        ax(owned.pid, window['windowId'], 'geometry', *geometry)
        if max(geometry[2:]) * scale > 1600:
            # 等待 AX 几何提交，只读确认，不能拿旧小窗口证明新窗口超限。
            deadline = time.monotonic() + 4
            while True:
                current = next(w for w in call('windows')['windows'] if w['windowId'] == window['windowId'])
                if tuple(current['bounds'][k] for k in ['x', 'y', 'width', 'height']) == geometry:
                    break
                assert time.monotonic() < deadline, current
                time.sleep(0.05)
            call('observe', '--connection', connection, expected_error='IMAGE_TOO_LARGE')
            print('PASS: 原生图像超限明确拒绝，未缩放为1600继续输入', geometry)
            continue
        tested_geometries += 1
        observed = observe_fixture_geometry(connection, geometry)
        assert observed.get('coordinateSpace') == 'frame-pixels' and observed.get('imageTransform') == 'crop-only', observed
        assert observed['width'] == round(geometry[2] * scale) and observed['height'] == round(geometry[3] * scale), observed
        if index == 0:
            # 先唤出控制条，再取帧，覆盖控制条已显示时的图像内容坐标。
            call('press', '--connection', connection, '--frame', observed['frameId'], '--key', 'Tab')
            observed = observe_fixture_geometry(connection, geometry)
        markers = ax(owned.pid, window['windowId'], 'markers', observed['imagePath'])
        bounds = observed['bounds']
        print('FRAME', json.dumps({k: observed.get(k) for k in ['width', 'height', 'bounds', 'captureBackend']}))
        for target in ['top', 'middle', 'bottom']:
            element = ax(owned.pid, window['windowId'], 'element', 'Copis target ' + target)
            screen_x = element['x'] + element['width'] / 2
            screen_y = element['y'] + element['height'] / 2
            x = round((screen_x - bounds['x']) * observed['width'] / bounds['width'])
            y = round((screen_y - bounds['y']) * observed['height'] / bounds['height'])
            marker = markers[target]
            image_error = [round(marker['x'] - x, 2), round(marker['y'] - y, 2)]
            print('IMAGE_ALIGNMENT', json.dumps({'target': target, 'expected': [x, y], 'detected': marker, 'error': image_error}))
            assert max(abs(v) for v in image_error) <= 2, image_error
            # 使用 JPEG 里测得的坐标发起点击，避免 AX 反算形成自证闭环。
            click_x, click_y = round(marker['x']), round(marker['y'])
            receipt = call('click', '--connection', connection, '--frame', observed['frameId'], '--x', click_x, '--y', click_y)
            expected_point = {'x': bounds['x'] + click_x * bounds['width'] / observed['width'],
                              'y': bounds['y'] + click_y * bounds['height'] / observed['height']}
            assert max(abs(receipt['screenPoint'][axis] - expected_point[axis]) for axis in ['x', 'y']) < 0.001, receipt
            deadline = time.monotonic() + 2
            while True:
                title = ax(owned.pid, window['windowId'], 'title')['title']
                event = json.JSONDecoder().raw_decode(title.split(':', 1)[1])[0] if ':' in title else {}
                if event.get('target') == target or time.monotonic() >= deadline:
                    break
                time.sleep(0.05)
            assert event.get('target') == target, (target, element, event)
            error = [round(event['screenX'] - screen_x, 2), round(event['screenY'] - screen_y, 2)]
            print('LANDING', json.dumps({'target': target, 'image': [x, y], 'expectedScreen': [screen_x, screen_y], 'event': event, 'error': error}))
            assert max(abs(v) for v in error) <= 2, error
            # 后两次目标相距200px，应有多个真实mousemove事件，而非一次瞬移。
            if target != 'top':
                assert event['movements'] >= 3 and event['trusted'], ('缺少真实连续移动', event)
            if target == 'middle':
                call('type', '--connection', connection, '--frame', observed['frameId'], '--text', '名筑')
                value = ax(owned.pid, window['windowId'], 'element', 'Copis target middle')['value']
                assert value == '名筑', value
                call('press', '--connection', connection, '--frame', observed['frameId'], '--key', 'Cmd+A')
                call('press', '--connection', connection, '--frame', observed['frameId'], '--key', 'Backspace')
        # 双击只在第一下之前移动，第二下仍保留系统double-click语义。
        marker = markers['top']
        receipt = call('click', '--connection', connection, '--frame', observed['frameId'], '--x', round(marker['x']), '--y', round(marker['y']), '--count', 2)
        deadline = time.monotonic() + 2
        while True:
            title = ax(owned.pid, window['windowId'], 'title')['title']
            event = json.JSONDecoder().raw_decode(title.split(':', 1)[1])[0] if ':' in title else {}
            if event.get('detail') == 2 or time.monotonic() >= deadline:
                break
            time.sleep(0.05)
        assert event.get('target') == 'top' and event.get('detail') == 2 and event.get('movements') == 0, ('双击之间不应重新移动', event)
        print('PASS: 实际页面收到连续mousemove且双击之间无重复移动', geometry)
        # 鼠标点击被顶部HUD覆盖的地址栏，验证横向避让后真正取得原生焦点。
        address = ax(owned.pid, window['windowId'], 'address')
        address_x = round((address['x'] + address['width']/2 - bounds['x']) * observed['width']/bounds['width'])
        address_y = round((address['y'] + address['height']/2 - bounds['y']) * observed['height']/bounds['height'])
        call('click', '--connection', connection, '--frame', observed['frameId'], '--x', address_x, '--y', address_y)
        assert ax(owned.pid, window['windowId'], 'focused-address')['focused'] is True
        call('press', '--connection', connection, '--frame', observed['frameId'], '--key', 'Escape')
        print('PASS: 顶部HUD横向避让后地址栏取得真实焦点，未导航或输入', geometry)
    call('disconnect', '--connection', connection)
    assert tested_geometries > 0, '主屏逻辑区域不足，无法验证坐标；需要至少容纳一个测试窗口'
    print(f'PASS: {tested_geometries} 种窗口几何、图像与落点正确、连续拟人移动、双击只移动一次；同帧输入通过')
finally:
    try:
        call('daemon', 'stop')
    finally:
        if owned:
            if window:
                try:
                    ax(owned.pid, window['windowId'], 'background', desktop['pid'])
                except (AssertionError, OSError, subprocess.TimeoutExpired):
                    pass
            owned.terminate()
            try:
                owned.wait(timeout=5)
            except subprocess.TimeoutExpired:
                owned.kill()
                owned.wait(timeout=3)
        server.shutdown()
        server.server_close()
PY
