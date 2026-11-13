#!/usr/bin/env python3
"""Run inside the built desktop: python3 /path/to/docker_smoke.py.

The fixture's own JavaScript reports visible page behavior to its HTTP server.
MCC never injects or evaluates scripts during these tests.
"""
import http.server
import base64
import ctypes
import ctypes.util
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import tempfile
import threading
import time

PAGE = r'''<!doctype html><meta charset="utf-8"><title>MCC Docker test</title>
<style>body{margin:0;font:24px sans-serif;height:2400px;background:#f8fafc}
h1{position:absolute;left:80px;top:15px;font-size:28px}
button{position:absolute;left:80px;top:100px;width:220px;height:50px;font-size:22px}
input{position:absolute;left:80px;top:190px;width:360px;height:42px;font-size:22px}
#drag{position:absolute;left:80px;top:300px;width:80px;height:80px;background:#0284c7;color:white}
#result{position:absolute;left:80px;top:410px}</style>
<h1>MCC Docker Test 容器测试</h1><button id="button">Click test 测试按钮</button>
<input id="input" placeholder="Type here"><div id="drag">Drag</div><p id="result">Ready</p>
<script>
const report=(kind,value)=>fetch('/event',{method:'POST',body:JSON.stringify({kind,value})});
requestAnimationFrame(()=>requestAnimationFrame(()=>report('ready',location.pathname)));
report('viewport',{x:window.mozInnerScreenX,y:window.mozInnerScreenY,width:innerWidth,height:innerHeight,path:location.pathname});
button.onclick=()=>{result.textContent='Clicked';report('click',true)};
button.oncontextmenu=e=>{e.preventDefault();report('right',true)};
input.oninput=()=>report('text',input.value);
document.addEventListener('wheel',e=>report('wheel',e.deltaY));
document.addEventListener('pointermove',e=>report('motion',{
  x:e.clientX,y:e.clientY,buttons:e.buttons,at:performance.now()}));
document.addEventListener('pointerdown',e=>report('down',{
  x:e.clientX,y:e.clientY,buttons:e.buttons,at:performance.now()}));
document.addEventListener('keydown',e=>report('key',{key:e.key,ctrl:e.ctrlKey,shift:e.shiftKey}));
let dragging=false;
drag.onpointerdown=e=>{dragging=true;drag.setPointerCapture(e.pointerId)};
drag.onpointermove=e=>{if(dragging){drag.style.left=(e.clientX-40)+'px';drag.style.top=(e.clientY-40)+'px'}};
drag.onpointerup=e=>{dragging=false;report('drag',{x:e.clientX,y:e.clientY})};
if(location.pathname==='/persist') {document.cookie='mcc_smoke=retained; path=/; max-age=3600';report('cookieSet',true)}
if(location.pathname==='/check') report('cookie',document.cookie.includes('mcc_smoke=retained'));
</script>'''.encode()
events = []


class DesktopClient:
    """Real noVNC WebSocket/RFB path; credentials never leave this process."""
    def __init__(self):
        self.socket = socket.create_connection(('127.0.0.1', 6080), timeout=3)
        key = base64.b64encode(os.urandom(16)).decode()
        self.socket.sendall((f'GET /websockify HTTP/1.1\r\nHost: 127.0.0.1:6080\r\n'
                             'Upgrade: websocket\r\nConnection: Upgrade\r\n'
                             f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n'
                             'Sec-WebSocket-Protocol: binary\r\n\r\n').encode())
        header = b''
        while not header.endswith(b'\r\n\r\n'):
            header += self.raw(1)
            assert len(header) < 8192
        assert header.startswith(b'HTTP/1.1 101 '), 'noVNC WebSocket upgrade failed'
        self.buffer = b''
        assert self.read(12).startswith(b'RFB ')
        self.send(b'RFB 003.008\n')
        security = self.read(self.read(1)[0])
        assert 2 in security and 1 not in security, 'RFB must require a password'
        self.send(b'\x02')
        challenge = self.read(16)
        with open(os.environ['MCC_VNC_PASSWORD_FILE'], 'rb') as secret:
            password = secret.read(9).rstrip(b'\r\n')
        assert len(password) == 8
        # VNC uses DES with each password byte's bits reversed. libcrypto is
        # already a desktop dependency; use its memory API, never process args.
        crypto = ctypes.CDLL(ctypes.util.find_library('crypto'))
        key_bytes = bytes(int(f'{byte:08b}'[::-1], 2) for byte in password)
        schedule = (ctypes.c_uint64 * 16)()
        crypto.DES_set_key_unchecked(ctypes.create_string_buffer(key_bytes), schedule)
        response = b''
        for offset in (0, 8):
            output = ctypes.create_string_buffer(8)
            crypto.DES_ecb_encrypt(ctypes.create_string_buffer(challenge[offset:offset + 8]),
                                   output, schedule, 1)
            response += output.raw
        self.send(response)
        assert self.read(4) == b'\0' * 4, 'RFB password authentication failed'
        self.send(b'\x01')
        init = self.read(24)
        self.width, self.height = struct.unpack('!HH', init[:4])
        self.read(struct.unpack('!I', init[20:24])[0])

    def raw(self, length):
        data = b''
        while len(data) < length:
            part = self.socket.recv(length - len(data))
            assert part, 'noVNC connection closed'
            data += part
        return data

    def read(self, length):
        while len(self.buffer) < length:
            first, size = self.raw(2)
            assert not size & 128, 'server WebSocket frame cannot be masked'
            size &= 127
            if size == 126:
                size = struct.unpack('!H', self.raw(2))[0]
            elif size == 127:
                size = struct.unpack('!Q', self.raw(8))[0]
            assert size <= 4 * 1024 * 1024
            data = self.raw(size)
            opcode = first & 15
            if opcode == 9:
                self.send(data, opcode=10)
            else:
                assert opcode in (0, 2), 'unexpected RFB WebSocket frame'
                self.buffer += data
        result, self.buffer = self.buffer[:length], self.buffer[length:]
        return result

    def send(self, data, opcode=2):
        mask = os.urandom(4)
        assert len(data) < 126
        self.socket.sendall(bytes([128 | opcode, 128 | len(data)]) + mask +
                            bytes(byte ^ mask[i % 4] for i, byte in enumerate(data)))

    def pointer(self, x, y, buttons=0):
        self.send(struct.pack('!BBHH', 5, buttons, x, y))

    def click(self, x, y):
        self.pointer(x, y)
        self.pointer(x, y, 1)
        time.sleep(.08)
        self.pointer(x, y)

    def close(self):
        self.socket.close()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/slow':
            events.append({'kind': 'slowLoad', 'value': True})
            time.sleep(1)
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def do_POST(self):
        events.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_):
        pass


def cli(*args, ok=True):
    result = subprocess.run(['mcc', *map(str, args)], text=True, capture_output=True, timeout=45)
    value = json.loads(result.stdout)
    if ok:
        assert result.returncode == 0 and value['ok'], (args[0], value)
    else:
        assert result.returncode != 0 and not value['ok'], (args[0], value)
    return value


def event(kind, predicate=lambda _: True, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if any(e['kind'] == kind and predicate(e['value']) for e in events):
            return
        time.sleep(0.02)
    raise AssertionError((kind, events))


def state_when(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = cli('control', '--command', 'state')
        if predicate(state):
            return state
        time.sleep(.02)
    raise AssertionError(('control state timeout', state))


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'
profile = 'smoke-' + str(os.getpid())
# Match Firefox's own test setting to keep first-run UI out of this fixture.
# Production profiles retain the ordinary notice for their user in noVNC.
profile_path = Path(os.environ['MCC_FIREFOX_PROFILE_ROOT']) / profile
profile_path.mkdir(mode=0o700)
(profile_path / 'user.js').write_text('user_pref("termsofuse.bypassNotification", true);\n')
connection = None
try:
    assert cli('permissions')['platform'] == 'linux-docker'
    launching = subprocess.Popen(['mcc', 'firefox', 'start', '--profile', profile,
                                 '--url', base + '/slow'], stdout=subprocess.PIPE, text=True)
    time.sleep(.1)
    cli('control', '--command', 'pause')
    cancelled_start = json.loads(launching.communicate(timeout=20)[0])
    assert launching.returncode != 0 and cancelled_start['error']['reason'] == 'USER_PAUSED', cancelled_start
    cli('control', '--command', 'resume')
    connection = cli('firefox', 'start', '--profile', profile, '--url', base + '/persist')['connectionId']
    event('cookieSet')
    event('ready', lambda path: path=='/persist')
    observation = cli('observe', '--connection', connection)
    assert observation['width'] == observation['bounds']['width']
    assert observation['height'] == observation['bounds']['height']
    event('viewport', lambda p: p['path']=='/persist')
    viewport=next(e['value'] for e in reversed(events) if e['kind']=='viewport' and e['value']['path']=='/persist')
    ox=int(viewport['x']-observation['bounds']['x']); oy=int(viewport['y']-observation['bounds']['y'])
    assert oy>0, 'native window screenshot must include browser toolbar'
    assert subprocess.run(['pgrep','-x','geckodriver'],stdout=subprocess.DEVNULL).returncode != 0
    cmdline=Path('/proc/'+str(cli('daemon','status')['window']['pid'])+'/cmdline').read_bytes()
    assert b'--marionette' not in cmdline and b'--remote-debugging' not in cmdline, cmdline
    print('PASS: ordinary Firefox, no driver, native window screenshot and physical pointer',flush=True)
    assert os.path.getsize(observation['imagePath']) > 0
    assert observation['ocr']['status'] == 'ok' and observation['ocr']['items']
    frame = observation['frameId']

    def coordinates(args):
        args=list(args)
        for i,arg in enumerate(args):
            if arg in ('--x','--from-x','--to-x'):args[i+1]=int(args[i+1])+ox
            if arg in ('--y','--from-y','--to-y'):args[i+1]=int(args[i+1])+oy
        return args

    def action(command, *args, ok=True):
        return cli(command, '--connection', connection, '--frame', frame, *coordinates(args), ok=ok)

    def steps_for_window(steps):
        for step in steps:
            if step['type'] in ('move','scroll'):
                step['x']+=ox; step['y']+=oy
        return steps


    latest = cli('observe', '--connection', connection)
    stale = action('click', '--x', 150, '--y', 125, ok=False)
    assert stale['error']['code'] == 'CONTEXT_CHANGED', stale
    frame = latest['frameId']
    # Observe actual page events and physical X11 pointer continuity.
    first_input_started = time.monotonic()
    action('move', '--x', 100, '--y', 500, '--duration-ms', 0)
    assert time.monotonic() - first_input_started < 2.5, 'Docker input still waits for a human countdown'
    marker = len(events)
    action('move', '--x', 1000, '--y', 500, '--duration-ms', 600)
    event('motion', lambda p: p['x'] == 1000 and p['y'] == 500)
    points = sorted([e['value'] for e in events[marker:] if e['kind'] == 'motion'], key=lambda p: p['at'])
    assert len(points) >= 6, ('too few actual movement events', points)
    assert all(100 <= p['x'] <= 1000 and abs(p['y'] - 500) <= 29 for p in points), points
    assert (points[-1]['x'], points[-1]['y']) == (1000, 500), points
    deltas = [b['x'] - a['x'] for a, b in zip(points, points[1:])]
    assert all(d >= 0 for d in deltas), ('longitudinal overshoot', deltas)
    assert deltas[0] < max(deltas) and deltas[-1] < max(deltas), ('missing easing', deltas)
    location=dict(line.split('=',1) for line in subprocess.check_output(['xdotool','getmouselocation','--shell'],text=True).splitlines())
    assert int(location['X'])==viewport['x']+1000 and int(location['Y'])==viewport['y']+500, location
    print('PASS: real page motion/easing, exact physical pointer endpoint and continuity', flush=True)

    marker = len(events)
    action('click', '--x', 150, '--y', 125)
    event('click')
    points = sorted([e['value'] for e in events[marker:] if e['kind'] == 'motion'], key=lambda p: p['at'])
    assert len(points) >= 6, ('click must approach through a trajectory', points)
    downs = [e['value'] for e in events[marker:] if e['kind'] == 'down']
    assert downs and downs[-1]['x'] == 150 and downs[-1]['y'] == 125, downs
    assert all(p['buttons'] == 0 for p in points), ('button held during approach', points)
    action('click', '--x', 150, '--y', 125, '--button', 'right')
    event('right')
    action('click', '--x', 160, '--y', 210)
    action('type', '--text', 'Hello 容器 é😀\ue008')
    event('text', lambda value: value == 'Hello 容器 é😀\ue008')
    action('press', '--key', 'Control+a')
    event('key', lambda value: value['ctrl'] and value['key'].lower() == 'a')
    action('hover', '--x', 500, '--y', 250, '--duration-ms', 100)
    action('drag', '--from-x', 120, '--from-y', 340, '--to-x', 340, '--to-y', 340, '--duration-ms', 250)
    event('drag', lambda value: value['x'] == 340 and value['y'] == 340)
    action('scroll', '--x', 600, '--y', 500, '--delta-y', 300)
    event('wheel', lambda value: value > 0)
    print('PASS: native window JPEG/OCR and system input', flush=True)

    # A held human modifier rejects only this operation and must stay human-owned.
    subprocess.run(['xdotool', 'keydown', 'Shift_L'], check=True)
    try:
        busy = action('move', '--x', 500, '--y', 300, '--duration-ms', 0, ok=False)
        assert busy['error'].get('reason', busy['error']['code']) == 'INPUT_BUSY', busy
        assert not cli('control', '--command', 'state')['paused']
    finally:
        subprocess.run(['xdotool', 'keyup', 'Shift_L'], check=True)
    action('move', '--x', 500, '--y', 300, '--duration-ms', 0)

    # Losing focus stops the current command without requiring an explicit Resume.
    root_info = subprocess.check_output(['xwininfo', '-root'], text=True)
    root_window = re.search(r'Window id: (0x[0-9a-fA-F]+)', root_info).group(1)
    running = subprocess.Popen(['mcc', 'hover', '--connection', connection,
                                '--frame', frame, *map(str, coordinates([
                                    '--x', 600, '--y', 300, '--duration-ms', 2000]))],
                               stdout=subprocess.PIPE, text=True)
    state_when(lambda state: state['active'])
    subprocess.run(['xdotool', 'windowfocus', root_window], check=True)
    unfocused = json.loads(running.communicate(timeout=15)[0])
    assert running.returncode != 0 and unfocused['error'].get('reason', unfocused['error']['code']) == 'FOCUS_LOST', unfocused
    assert unfocused['error']['receipt']['inputState'] == 'released', unfocused
    assert not cli('control', '--command', 'state')['paused']
    frame = cli('observe', '--connection', connection)['frameId']
    action('move', '--x', 500, '--y', 300, '--duration-ms', 0)
    print('PASS: held human key and focus loss reject one command without a pause latch', flush=True)

    # A pause during the approach must stop the click before any button-down.
    action('move', '--x', 1000, '--y', 550, '--duration-ms', 0)
    marker = len(events)
    running = subprocess.Popen(['mcc', 'click', '--connection', connection,
                                '--frame', frame, *map(str,coordinates(['--x',150,'--y',125]))],
                               stdout=subprocess.PIPE, text=True)
    state_when(lambda state: state['active'])
    time.sleep(.08)
    cli('control', '--command', 'pause')
    interrupted_click = json.loads(running.communicate(timeout=15)[0])
    assert running.returncode != 0 and not interrupted_click['ok'], interrupted_click
    assert interrupted_click['error']['receipt']['dispatchState'] == 'partial', interrupted_click
    assert interrupted_click['error']['receipt']['inputState'] == 'released', interrupted_click
    assert not any(e['kind'] == 'down' for e in events[marker:]), 'paused approach still clicked'
    print('PASS: pause during curved approach prevents the click', flush=True)
    cli('control', '--command', 'resume')

    cli('control', '--command', 'pause')
    paused = action('move', '--x', 20, '--y', 20, '--duration-ms', 50, ok=False)
    assert paused['error']['reason'] == 'USER_PAUSED'
    cli('control', '--command', 'resume')
    action('move', '--x', 20, '--y', 20, '--duration-ms', 50)
    assert cli('control', '--command', 'state')['inputState'] == 'released'
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json') as sequence:
        json.dump({'version': 1, 'steps': steps_for_window([
            {'type': 'move', 'x': 500, 'y': 300, 'durationMs': 0},
            {'type': 'pointerDown', 'button': 'left'},
            {'type': 'move', 'x': 900, 'y': 500, 'durationMs': 2000},
            {'type': 'pointerUp', 'button': 'left'}])}, sequence)
        sequence.flush()
        running = subprocess.Popen(['mcc', 'actions', '--connection', connection,
                                    '--frame', frame, '--file', sequence.name],
                                   stdout=subprocess.PIPE, text=True)
        state_when(lambda state: state['active'])
        time.sleep(.2)
        cli('control', '--command', 'pause')
        interrupted = json.loads(running.communicate(timeout=15)[0])
        assert running.returncode != 0 and not interrupted['ok'], interrupted
        assert interrupted['error']['receipt']['dispatchState'] == 'partial', interrupted
        assert interrupted['error']['receipt']['inputState'] == 'released', interrupted
    cli('control', '--command', 'resume')
    desktop = DesktopClient()
    try:
        desktop.pointer(900, 650)
        time.sleep(.1)
        assert not cli('control', '--command', 'state')['paused'], 'ordinary noVNC movement paused Docker'
        action('move', '--x', 20, '--y', 20, '--duration-ms', 50)
        desktop.click(20, 18)   # visible Pause button
        state_when(lambda state: state['paused'])
        desktop.click(110, 18)
        state_when(lambda state: not state['paused'])
        desktop.click(190, 18)  # visible Cancel button
        state_when(lambda state: state['paused'] and state['pauseReason'] == 'explicitCancel')
        cli('control', '--command', 'resume')
    finally:
        desktop.close()
    print('PASS: no passive noVNC pause; explicit in-flight pause/release and control buttons', flush=True)
    cli('disconnect', '--connection', connection)
    connection = None
    connection = cli('firefox', 'start', '--profile', profile, '--url', base + '/check')['connectionId']
    event('cookie', lambda value: value is True)
    frame = cli('observe', '--connection', connection)['frameId']
    action('move', '--x', 500, '--y', 300, '--duration-ms', 0)
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json') as sequence:
        json.dump({'version': 1, 'steps': steps_for_window([
            {'type': 'move', 'x': 500, 'y': 300},
            {'type': 'pointerDown', 'button': 'left'},
            {'type': 'pause', 'durationMs': 2000},
            {'type': 'pointerUp', 'button': 'left'}])}, sequence)
        sequence.flush()
        pid=cli('daemon','status')['window']['pid']
        running = subprocess.Popen(['mcc', 'actions', '--connection', connection,
                                    '--frame', frame, '--file', sequence.name],
                                   stdout=subprocess.PIPE, text=True)
        state_when(lambda state: state['active'])
        time.sleep(.2)
        os.kill(pid,15)
        failed=json.loads(running.communicate(timeout=20)[0])
        assert running.returncode != 0 and not failed['ok'], failed
        assert failed['error']['receipt']['inputState']=='released', failed
    cli('disconnect','--connection',connection)
    connection=None
    if cli('control','--command','state')['paused']:
        cli('control','--command','resume')
    connection=cli('firefox','start','--profile',profile,'--url',base+'/check')['connectionId']
    print(json.dumps({'ok': True, 'checks': ['ordinary Firefox without WebDriver', 'no human countdown', 'Bezier/minimum-jerk page motion', 'physical X11 pointer continuity', 'curved approach before click', 'pause during approach prevents click', 'native window JPEG', 'local OCR', 'left/right click', 'Unicode typing', 'Control chord', 'hover', 'drag', 'wheel', 'held human key without a pause latch', 'focus loss and next-command reactivation', 'explicit pause/resume', 'in-flight pause with partial receipt', 'input release', 'noVNC password/WebSocket/RFB', 'no passive noVNC pause', 'visible Pause/Resume/Cancel', 'persistent profile', 'browser exit with confirmed X11 release', 'explicit disconnect and fresh start']}))
finally:
    if connection:
        cli('disconnect', '--connection', connection)
    server.shutdown()
