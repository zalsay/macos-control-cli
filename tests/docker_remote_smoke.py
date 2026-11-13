#!/usr/bin/env python3
"""Run in the desktop container to exercise real TLS/Host/Linux peer/Firefox."""
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time

clicked = threading.Event()
held = threading.Event()
viewport = {}
page = b'''<!doctype html><title>MCC remote test</title>
<button style="position:absolute;left:80px;top:100px;width:220px;height:60px"
 onpointerdown="fetch('/held')"
 onclick="fetch('/clicked').then(()=>this.textContent='Clicked')">Remote click</button><script>fetch('/viewport?x='+mozInnerScreenX+'&y='+mozInnerScreenY)</script>'''


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/viewport?'):
            from urllib.parse import parse_qs,urlsplit
            viewport.update({k:int(v[0]) for k,v in parse_qs(urlsplit(self.path).query).items()})
        if self.path == '/clicked':
            clicked.set()
        if self.path == '/held':
            held.set()
        self.send_response(200)
        self.send_header('Content-Length', str(len(page)))
        self.end_headers()
        self.wfile.write(page)

    def log_message(self, *_):
        pass


def cli(*args, ok=True):
    result = subprocess.run(['mcc', *map(str, args)], capture_output=True, text=True, timeout=45)
    value = json.loads(result.stdout)
    assert (result.returncode == 0 and value['ok']) == ok, value
    return value


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
with tempfile.TemporaryDirectory(prefix='mcc-wss-', dir='/tmp') as directory:
    root = Path(directory)
    cli('host', 'tls', 'init', '--ip', '127.0.0.1', '--output-dir', root / 'tls')
    cli('host', 'token', 'init', '--output', root / 'token')
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    with tempfile.TemporaryFile() as log:
        host = subprocess.Popen(['mcc', 'host', 'start', '--listen', f'127.0.0.1:{port}',
                                 '--tls-cert', str(root / 'tls/host-cert.pem'),
                                 '--tls-key', str(root / 'tls/host-key.pem'),
                                 '--token-file', str(root / 'token'),
                                 '--state-dir', str(root / 'host')],
                                stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        prefix = ['--remote', f'wss://127.0.0.1:{port}', '--ca-cert', root / 'tls/host-ca.pem',
                  '--token-file', root / 'token', '--remote-state-dir', root / 'client']
        connection = None
        try:
            deadline = time.monotonic() + 10
            while True:
                assert host.poll() is None, 'Host exited before readiness'
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.2):
                        break
                except OSError:
                    assert time.monotonic() < deadline, 'Host did not listen'
                    time.sleep(.05)
            profile = 'remote-smoke-' + str(os.getpid())
            profile_path = Path(os.environ['MCC_FIREFOX_PROFILE_ROOT']) / profile
            profile_path.mkdir(mode=0o700)
            (profile_path / 'user.js').write_text('user_pref("termsofuse.bypassNotification", true);\n')
            result = cli(*prefix, 'firefox', 'start', '--profile', profile,
                         '--url', f'http://127.0.0.1:{server.server_port}/')
            connection = result['connectionId']
            assert result['backend'] == 'firefox-x11'
            refused = cli('control', '--command', 'pause', ok=False)
            assert refused['error']['code'] == 'BUSY', refused
            deadline=time.monotonic()+5
            while time.monotonic()<deadline:
                visible = subprocess.run(['xdotool', 'search', '--onlyvisible', '--name',
                                          '^MCC remote test'], stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL).returncode == 0
                if viewport and visible:
                    break
                time.sleep(.02)
            assert viewport and visible, 'fixture window did not finish loading'
            observed = cli(*prefix, 'observe', '--connection', connection)
            ox=int(viewport['x']-observed['bounds']['x']); oy=int(viewport['y']-observed['bounds']['y'])
            assert oy>0
            assert Path(observed['imagePath']).is_file()
            result = cli(*prefix, 'click', '--connection', connection, '--frame', observed['frameId'],
                         '--x', 150+ox, '--y', 130+oy, '--button', 'left')
            assert result['backend'] == 'firefox-x11' and result['inputState'] == 'released'
            assert clicked.wait(5), 'X11 remote click did not reach the page'
            subprocess.run(['xdotool', 'mousemove', '950', '650'], check=True)
            time.sleep(.1)
            observed = cli(*prefix, 'observe', '--connection', connection)
            result = cli(*prefix, 'hover', '--connection', connection, '--frame', observed['frameId'],
                         '--x', 400, '--y', 250, '--duration-ms', 100)
            assert result['dispatchState'] == 'completed'
            with tempfile.NamedTemporaryFile(mode='w', suffix='.json') as sequence:
                json.dump({'version': 1, 'steps': [
                    {'type': 'move', 'x': 150+ox, 'y': 130+oy},
                    {'type': 'pointerDown', 'button': 'left'},
                    {'type': 'pause', 'durationMs': 2000},
                    {'type': 'pointerUp', 'button': 'left'}]}, sequence)
                sequence.flush()
                held.clear()
                running = subprocess.Popen(['mcc', *map(str, prefix), 'actions', '--connection', connection,
                                            '--frame', observed['frameId'], '--file', sequence.name],
                                           stdout=subprocess.PIPE, text=True)
                assert held.wait(5), 'remote Actions did not press the pointer'
                subprocess.run(['xdotool', 'mousemove', '950', '650'], check=True)
                completed = json.loads(running.communicate(timeout=15)[0])
                assert running.returncode == 0 and completed['dispatchState'] == 'completed', completed
                assert completed['inputState'] == 'released', completed
            # Explicit Pause remains available when the pointer is not grabbed.
            observed = cli(*prefix, 'observe', '--connection', connection)
            running = subprocess.Popen(['mcc', *map(str, prefix), 'hover', '--connection', connection,
                                        '--frame', observed['frameId'], '--x', '400', '--y', '250',
                                        '--duration-ms', '2000'], stdout=subprocess.PIPE, text=True)
            time.sleep(.5)
            subprocess.run(['xdotool', 'mousemove', '20', '18', 'click', '1'], check=True)
            partial = json.loads(running.communicate(timeout=15)[0])
            assert running.returncode != 0 and partial['error']['receipt']['dispatchState'] == 'partial', partial
            assert partial['error']['receipt']['inputState'] == 'released', partial
            refused = cli(*prefix, 'hover', '--connection', connection, '--frame', observed['frameId'],
                          '--x', 400, '--y', 250, ok=False)
            assert refused['error'].get('reason') == 'USER_PAUSED', refused
            subprocess.run(['xdotool', 'mousemove', '110', '18', 'click', '1'], check=True)
            time.sleep(.1)
            cli(*prefix, 'hover', '--connection', connection, '--frame', observed['frameId'],
                '--x', 400, '--y', 250, '--duration-ms', 100)
            cli(*prefix, 'disconnect', '--connection', connection)
            connection = None
            print(json.dumps({'ok': True, 'checks': ['TLS/token', 'Host Firefox capability negotiation',
                  'Linux peer identity and owner reservation', 'local owner exclusion', 'remote JPEG/OCR',
                  'page click result', 'remote hover', 'no passive movement pause during held input',
                  'manual pause/release with partial receipt', 'manual resume', 'disconnect']}))
        finally:
            try:
                if connection:
                    cli(*prefix, 'disconnect', '--connection', connection)
            finally:
                host.terminate()
                try:
                    host.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    host.kill()
                    host.wait(timeout=5)
                server.shutdown()
