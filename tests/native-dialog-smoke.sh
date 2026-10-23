#!/bin/bash
# 原生层级23隔离弹窗功能回归；会占用鼠标，只有显式执行时才运行。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cli="${1:?请传入 desktop-control 二进制绝对路径}"
scratch="$(mktemp -d /tmp/native-dialog.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
app="$scratch/NativeDialogFixture.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.copis.native-dialog-fixture</string>
<key>CFBundleName</key><string>NativeDialogFixture</string>
<key>CFBundleExecutable</key><string>fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
swiftc -O -warnings-as-errors "$root/tests/native-dialog-fixture/main.swift" -o "$app/Contents/MacOS/fixture"
python3 - "$cli" "$scratch" "$app" <<'PY'
import json, os, pathlib, subprocess, sys, time
cli, scratch, app = sys.argv[1:]; root = pathlib.Path(scratch)
env = dict(os.environ, COPIS_DESKTOP_RUNTIME_DIR=str(root / 'runtime'))
logs = (root / 'daemon-process.log').open('w')
daemon = subprocess.Popen([cli, 'daemon', 'run'], env=env, stdout=logs, stderr=logs)
fixture = subprocess.Popen([app + '/Contents/MacOS/fixture', scratch], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
connection = None

def call(*args, check=True):
    p = subprocess.run([cli, *map(str, args)], env=env, capture_output=True, text=True, timeout=25)
    r = json.loads(p.stdout)
    if check: assert r.get('ok'), r
    return r

def wait_json(name):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        try: return json.loads((root / name).read_text())
        except FileNotFoundError: time.sleep(.1)
    raise AssertionError('隔离 fixture 没有就绪')

try:
    identity = wait_json('fixture.json')
    windows = call('windows', '--app', 'com.copis.native-dialog-fixture')['windows']
    dialog = [w for w in windows if w['windowId'] == identity['dialogWindowId'] and w['pid'] == identity['pid']]
    assert len(dialog) == 1, ('层级23的原生授权弹窗必须可枚举', windows, identity)
    assert not set(identity['excludedWindowIds']) & {w['windowId'] for w in windows}, '菜单/状态层或未经证明的浮层被错误纳入'
    connection = call('connect', '--window', identity['dialogWindowId'])['connectionId']
    frame = call('observe', '--connection', connection)
    assert frame['width'] > 0 and frame['height'] > 0 and frame['imageTransform'] == 'crop-only', frame
    targets = [i for i in frame['ocr']['items'] if i['text'] == '允许测试']
    assert len(targets) == 1, frame.get('ocr')
    c = targets[0]['center']
    call('click', '--connection', connection, '--frame', frame['frameId'], '--x', c['x'], '--y', c['y'])
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline and wait_json('clicks.json')['clicks'] != 1: time.sleep(.05)
    assert wait_json('clicks.json')['clicks'] == 1, '事件投递成功不等于按钮收到点击'
    # 非激活面板不能让键盘输入落到应用的主窗口。
    blocked = call('type', '--connection', connection, '--frame', frame['frameId'], '--text', 'must-not-reach-main-window', check=False)
    assert blocked.get('ok') is False and blocked['error']['code'] in ['FOCUS_LOST', 'FOCUS_UNVERIFIED'] and 'reason' not in blocked['error'], blocked
    (root / 'cover.trigger').touch()
    wait_json('cover.json')
    blocked = call('click', '--connection', connection, '--frame', frame['frameId'], '--x', c['x'], '--y', c['y'], check=False)
    assert blocked.get('ok') is False and blocked['error']['code'] in ['POINTER_OBSCURED', 'POINTER_UNVERIFIED'], blocked
    assert wait_json('clicks.json')['clicks'] == 1, '遮挡时不能把点击穿透到原生弹窗'
    (root / 'dialog.close').touch()
    wait_json('closed.json')
    blocked = call('click', '--connection', connection, '--frame', frame['frameId'], '--x', c['x'], '--y', c['y'], check=False)
    assert blocked.get('ok') is False and blocked['error']['code'] == 'WINDOW_UNAVAILABLE', blocked
    assert wait_json('clicks.json')['clicks'] == 1, '原弹窗关闭后不能重定向到另一个窗口'
    print('PASS: 层级23非激活原生弹窗枚举/独立连接/原图OCR/真实点击，菜单状态层排除、键盘误投/遮挡穿透/关闭重定向拒绝；未操作用户应用')
finally:
    try:
        if connection:
            subprocess.run([cli, 'disconnect', '--connection', connection], env=env, capture_output=True, timeout=10)
        subprocess.run([cli, 'daemon', 'stop'], env=env, capture_output=True, timeout=12)
        status = call('daemon', 'status')
        assert status['running'] is False, status
    finally:
        (root / 'fixture.stop').touch()
        for proc in [daemon, fixture]:
            try: proc.wait(timeout=5)
            except subprocess.TimeoutExpired: proc.terminate(); proc.wait(timeout=5)
        logs.close()
PY
