#!/bin/bash
# 显式桌面回归：只创建/操作临时TextEdit文件与Finder目录，不修改用户业务内容。
set -euo pipefail
if [[ "$(uname -s)" != Darwin || $# != 1 ]]; then
  echo '用法：bash tests/application-smoke.sh <desktop-control绝对路径>' >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d /tmp/copis-app-control.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
swiftc -O -warnings-as-errors "$root/tests/application-fixture/main.swift" -o "$scratch/fixture-ax"
python3 - "$1" "$scratch" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import time

cli = str(Path(sys.argv[1]).resolve(strict=True))
scratch = Path(sys.argv[2])
env = dict(os.environ, COPIS_DESKTOP_RUNTIME_DIR=str(scratch / 'runtime'))
fixture = scratch / 'fixture-ax'
folder = scratch / ('DesktopControlFixture-' + scratch.name)
folder.mkdir()
textfile = folder / ('DesktopControlFixture-' + scratch.name + '.txt')
textfile.write_text('DesktopControlFixture text selection', encoding='utf-8')
(folder / 'DesktopControlTarget.txt').write_text('仅供本机窗口控制回归，不上传。', encoding='utf-8')

def ax(window, action):
    r = subprocess.run([str(fixture), str(window['pid']), str(window['windowId']), action], capture_output=True, text=True, timeout=8)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout) if r.stdout.strip() else None

def call(*args):
    r = subprocess.run([cli, *map(str, args)], env=env, capture_output=True, text=True, timeout=30)
    v = json.loads(r.stdout)
    assert r.returncode == 0 and v['ok'], v
    return v

def await_window(bundle, title):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        match = next((w for w in call('windows', '--app', bundle)['windows'] if title in w['title']), None)
        if match:
            return match
        time.sleep(0.1)
    raise AssertionError('找不到本次测试窗口：' + bundle)

def observe(connection):
    deadline = time.monotonic() + 8
    while True:
        r = subprocess.run([cli, 'observe', '--connection', connection], env=env, capture_output=True, text=True, timeout=25)
        v = json.loads(r.stdout)
        if v.get('ok'):
            return v
        assert v['error']['code'] == 'FRAME_GEOMETRY_CHANGED' and time.monotonic() < deadline, v
        time.sleep(0.05)

owned = []
connection = None
try:
    subprocess.run(['/usr/bin/open', '-g', '-a', 'TextEdit', str(textfile)], check=True)
    editor = await_window('com.apple.TextEdit', textfile.name)
    owned.append(editor)
    ax(editor, 'geometry')
    connection = call('connect', '--window', editor['windowId'])['connectionId']
    frame = observe(connection)
    target = next(e for e in frame['ocr']['items'] if 'text selection' in e['text'].lower())
    receipt = call('click', '--connection', connection, '--frame', frame['frameId'], '--x', target['center']['x'], '--y', target['center']['y'])
    call('press', '--connection', connection, '--frame', frame['frameId'], '--key', 'Cmd+A')
    focused = ax(editor, 'focus')
    assert focused['role'] == 'AXTextArea' and focused.get('selectionLength', 0) > 0, focused
    assert focused['value'] == textfile.read_text(), '测试不得修改文件内容'
    call('press', '--connection', connection, '--frame', frame['frameId'], '--key', 'ArrowRight')
    focused = ax(editor, 'focus')
    assert focused.get('selectionLength') == 0, focused
    call('disconnect', '--connection', connection)
    connection = None
    print('PASS: TextEdit 原图/OCR中心点击、Cmd+A实际选中文本、ArrowRight收起选择；文件内容未修改')
    subprocess.run(['/usr/bin/open', '-g', '-a', 'Finder', str(folder)], check=True)
    finder = await_window('com.apple.finder', folder.name)
    owned.append(finder)
    ax(finder, 'geometry')
    connection = call('connect', '--window', finder['windowId'])['connectionId']
    frame = observe(connection)
    candidates = [e for e in ax(finder, 'elements')['elements'] if e['name'].startswith('DesktopControlTarget') and e['width'] > 0 and e['height'] > 0]
    assert candidates, 'Finder测试文件没有可核对的几何'
    target = candidates[0]
    b = frame['bounds']
    x = round((target['x'] + target['width']/2 - b['x']) * frame['width']/b['width'])
    y = round((target['y'] + target['height']/2 - b['y']) * frame['height']/b['height'])
    call('click', '--connection', connection, '--frame', frame['frameId'], '--x', x, '--y', y)
    call('press', '--connection', connection, '--frame', frame['frameId'], '--key', 'Cmd+A')
    selected = ax(finder, 'elements')['elements']
    assert any(e['selected'] for e in selected), 'Finder未收到选择操作'
    call('disconnect', '--connection', connection)
    connection = None
    assert textfile.read_text() == 'DesktopControlFixture text selection'
    print('PASS: Finder私有目录原图/OCR、精确窗口点击、Cmd+A实际选择；未打开或修改用户文件')
finally:
    try:
        if connection:
            try: call('disconnect', '--connection', connection)
            except Exception: pass
        call('daemon', 'stop')
        assert call('daemon', 'status')['running'] is False
    finally:
        for window in reversed(owned):
            try: ax(window, 'close')
            except Exception: pass
PY
