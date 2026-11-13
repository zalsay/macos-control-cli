#!/usr/bin/env python3
"""Run on the host against an isolated Host-enabled desktop (see MCC-DOCKER.md).

The fixture reports its own events; MCC only observes pixels and sends X11 input.
The provided container is used solely to prepare a fresh test profile.
"""
import argparse
from email import policy
from email.parser import BytesParser
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import threading


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mcc', type=Path, default=Path('target/debug/mcc'))
    parser.add_argument('--remote', required=True)
    parser.add_argument('--ca-cert', type=Path, required=True)
    parser.add_argument('--token-file', type=Path, required=True)
    parser.add_argument('--container', required=True, help='Dedicated test desktop, never a user session')
    parser.add_argument('--files', action='store_true', help='Also require Host uploads and native file selection')
    options = parser.parse_args()
    events = {}
    history = {}
    condition = threading.Condition()
    page = '''<!doctype html><meta charset="utf-8"><title>MCC external Host test</title>
<style>button,input{position:absolute;left:80px;width:360px;height:50px;font-size:22px}
button{top:100px}input{top:190px}</style>
<button id="button">External click</button><input id="input">
<form action="/upload" method="post" enctype="multipart/form-data">
<input hidden type="file" name="document" id="attachment">
<button type="button" id="choose" style="top:280px">Choose file</button>
<button type="submit" style="top:370px">Upload fixture</button></form>
<script>
const report=(kind,value)=>fetch('/event',{method:'POST',body:JSON.stringify({kind,value})});
button.onclick=()=>report('click',true);
input.oninput=()=>report('input',input.value);
document.getElementById('choose').onclick=()=>document.getElementById('attachment').click();
document.getElementById('attachment').onchange=e=>report('selected',
 {name:e.target.files[0].name,size:e.target.files[0].size});
requestAnimationFrame(()=>requestAnimationFrame(()=>report('ready',
 {x:mozInnerScreenX,y:mozInnerScreenY})));
</script>'''.encode()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(page)))
            self.end_headers()
            self.wfile.write(page)

        def do_POST(self):
            body = self.rfile.read(int(self.headers['Content-Length']))
            if self.path == '/upload':
                message = BytesParser(policy=policy.default).parsebytes(
                    ('Content-Type: ' + self.headers['Content-Type'] + '\r\n\r\n').encode() + body)
                parts = list(message.iter_parts())
                assert len(parts) == 1 and parts[0].get_param('name', header='content-disposition') == 'document'
                event = {'kind': 'uploaded', 'value': {
                    'name': parts[0].get_filename(), 'bytes': parts[0].get_payload(decode=True)}}
            else:
                event = json.loads(body)
            with condition:
                events[event['kind']] = event['value']
                history.setdefault(event['kind'], []).append(event['value'])
                condition.notify_all()
            self.send_response(204)
            self.end_headers()

        def log_message(self, *_):
            pass

    def wait_event(kind, predicate=lambda value: bool(value)):
        with condition:
            # Concurrent fetches can reach ThreadingHTTPServer out of order.
            # An older prefix must not hide the final input event already seen.
            def matching():
                return [value for value in history.get(kind, []) if predicate(value)]
            assert condition.wait_for(lambda: bool(matching()), 10), \
                f'No expected page event: {kind}; last value: {events.get(kind)!r}'
            return matching()[-1]

    server = http.server.ThreadingHTTPServer(('0.0.0.0', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='mcc-external-host-') as directory:
        root = Path(directory)
        prefix = ['--remote', options.remote, '--ca-cert', str(options.ca_cert.resolve()),
                  '--token-file', str(options.token_file.resolve()), '--remote-state-dir', str(root / 'client')]
        env = dict(os.environ, COPIS_DESKTOP_HELPER='/nonexistent/mcc-no-local-fallback')

        def cli(*args, ok=True, remote_prefix=prefix):
            result = subprocess.run([str(options.mcc.resolve()), *remote_prefix, *map(str, args)],
                                    env=env, capture_output=True, text=True, timeout=60)
            value = json.loads(result.stdout)
            assert (result.returncode == 0 and value.get('ok') is True) == ok, \
                f"Remote {args[0]}: {value.get('error', {}).get('code', result.returncode)}: " \
                f"{value.get('error', {}).get('message', '')}"
            return value

        connection = None
        try:
            cli('status')  # Fails on the pre-Host image even when Docker publishes the port.
            wrong = root / 'wrong.token'
            wrong.write_text(secrets.token_hex(32))
            wrong.chmod(0o600)
            rejected_prefix = list(prefix)
            rejected_prefix[rejected_prefix.index('--token-file') + 1] = str(wrong)
            refused = cli('status', ok=False, remote_prefix=rejected_prefix)
            assert refused['error']['code'] == 'REMOTE_CONNECT_FAILED', 'Expected opaque TLS/auth rejection'
            profile = 'external-host-smoke-' + str(os.getpid())
            prepare = '''import os; from pathlib import Path
p=Path(os.environ['MCC_FIREFOX_PROFILE_ROOT'])/os.sys.argv[1]
p.mkdir(mode=0o700)
(p/'user.js').write_text('user_pref("termsofuse.bypassNotification", true);\\n')
'''
            subprocess.run(['docker', 'exec', options.container, 'python3', '-c', prepare, profile], check=True)
            started = cli('firefox', 'start', '--profile', profile,
                          '--url', f'http://host.docker.internal:{server.server_port}/')
            connection = started['connectionId']
            assert started['backend'] == 'firefox-x11'
            viewport = wait_event('ready')
            observed = cli('observe', '--connection', connection, '--out', root / 'window.jpg')
            image = Path(observed['imagePath'])
            assert image.parent == root and image.read_bytes().startswith(b'\xff\xd8'), \
                'Remote JPEG was not downloaded to the host'
            ox = int(viewport['x'] - observed['bounds']['x'])
            oy = int(viewport['y'] - observed['bounds']['y'])
            assert oy > 0, 'Expected a native window including browser chrome'
            clicked = cli('click', '--connection', connection, '--frame', observed['frameId'],
                          '--x', ox + 150, '--y', oy + 125)
            assert clicked['inputState'] == 'released'
            wait_event('click')
            cli('click', '--connection', connection, '--frame', observed['frameId'],
                '--x', ox + 150, '--y', oy + 210)
            text = 'Host 容器输入 AI'
            cli('type', '--connection', connection, '--frame', observed['frameId'], '--text', text)
            wait_event('input', lambda value: value == text)
            actions = root / 'actions.json'
            actions.write_text(json.dumps({'version': 1, 'steps': [
                {'type': 'keyDown', 'key': 'Control'}, {'type': 'keyDown', 'key': 'a'},
                {'type': 'keyUp', 'key': 'a'}, {'type': 'keyUp', 'key': 'Control'},
                {'type': 'keyDown', 'key': 'X'}, {'type': 'keyUp', 'key': 'X'}]}))
            result = cli('actions', '--connection', connection, '--frame', observed['frameId'], '--file', actions)
            assert result['dispatchState'] == 'completed' and result['inputState'] == 'released'
            wait_event('input', lambda value: value == 'X')
            if options.files:
                def staged_names():
                    result = subprocess.run(['docker', 'exec', options.container, 'python3', '-c',
                        'import os,json; from pathlib import Path; p=Path(os.environ["MCC_UPLOAD_DIR"]); '
                        'print(json.dumps(sorted(x.name for x in p.iterdir() if x.name != ".lock")))'],
                        capture_output=True, text=True, check=True)
                    return json.loads(result.stdout)

                before_names = staged_names()
                source = root / '报告 with spaces.bin'
                content = bytes(range(256)) * 257 + b'\0\xffend'
                source.write_bytes(content)
                receipt = cli('file', 'put', '--connection', connection, '--local', source)
                file_id = receipt['fileId']
                assert receipt['name'] == source.name and receipt['bytes'] == len(content)
                assert receipt['sha256'] == hashlib.sha256(content).hexdigest()

                def refused(*args, codes, remote_prefix=prefix):
                    response = cli(*args, ok=False, remote_prefix=remote_prefix)
                    assert response['error']['code'] in codes or response['error'].get('reason') in codes, response
                    return response

                other = list(prefix)
                other[other.index('--remote-state-dir') + 1] = str(root / 'other-client')
                refused('select-file', '--connection', connection, '--file-id', file_id,
                        codes={'NOT_OWNER'}, remote_prefix=other)
                refused('file', 'put', '--connection', 'wrong-connection', '--local', source,
                        codes={'NOT_OWNER'})
                refused('select-file', '--connection', connection, '--file-id', 'missing-file',
                        codes={'FILE_NOT_ALLOWED'})
                refused('select-file', '--connection', connection, '--path', '/etc/hosts',
                        codes={'FILE_NOT_ALLOWED'})
                refused('select-file', '--connection', connection, '--file-id', file_id,
                        codes={'FILE_DIALOG_NOT_FOUND'})

                observed = cli('observe', '--connection', connection, '--out', root / 'before-picker.jpg')
                cli('click', '--connection', connection, '--frame', observed['frameId'],
                    '--x', ox + 150, '--y', oy + 305)
                wait_picker = '''import subprocess, sys, time
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    windows = subprocess.run(['xdotool', 'search', '--onlyvisible', '--pid', sys.argv[1]], capture_output=True, text=True).stdout.split()
    if any('GtkFileChooserDialog' in subprocess.run(['xprop', '-id', w, 'WM_WINDOW_ROLE'], capture_output=True, text=True).stdout for w in windows):
        break
    time.sleep(.02)
else:
    raise RuntimeError('Native Firefox picker did not open')
'''
                subprocess.run(['docker', 'exec', options.container, 'python3', '-c', wait_picker,
                                str(started['window']['pid'])], check=True)
                # A verified modal can retain the lease, but ordinary typing
                # must still refuse input while the browser parent lacks focus.
                refused('type', '--connection', connection, '--frame', observed['frameId'],
                        '--text', 'must-not-reach-picker', codes={'FOCUS_UNVERIFIED', 'FOCUS_LOST'})
                subprocess.run(['docker', 'exec', options.container, 'xdotool',
                                'mousemove', '20', '18', 'click', '1'], check=True)
                refused('select-file', '--connection', connection, '--file-id', file_id,
                        codes={'USER_PAUSED', 'FOCUS_LOST'})
                assert 'selected' not in events, 'Paused selection reached the page'
                subprocess.run(['docker', 'exec', options.container, 'xdotool',
                                'mousemove', '110', '18', 'click', '1'], check=True)
                selected = cli('select-file', '--connection', connection, '--file-id', file_id)
                assert selected['selected'] is True and selected['dialogClosed'] is True
                assert wait_event('selected') == {'name': source.name, 'size': len(content)}
                assert 'uploaded' not in events, 'Selecting a file must not submit the form'
                observed = cli('observe', '--connection', connection, '--out', root / 'before-upload.jpg')
                cli('click', '--connection', connection, '--frame', observed['frameId'],
                    '--x', ox + 150, '--y', oy + 395)
                assert wait_event('uploaded') == {'name': source.name, 'bytes': content}, \
                    'Browser multipart upload changed the original filename or bytes'
            cli('disconnect', '--connection', connection)
            connection = None
            if options.files:
                assert staged_names() == before_names, 'Disconnect left files from this connection'
            print(json.dumps({'ok': True, 'checks': ['published WSS port', 'TLS/token', 'bad token rejected',
                  'no local fallback', 'native Firefox', 'JPEG on host', 'system click', 'Unicode input',
                  'Actions from host file', 'explicit disconnect'] + (['WSS file transfer and SHA256',
                  'cross-session and wrong connection rejection', 'Host path policy', 'no picker rejection',
                  'ordinary input focus gate', 'paused picker rejection', 'native GTK file selection',
                  'real multipart bytes and Unicode filename', 'disconnect file cleanup'] if options.files else [])}))
        finally:
            try:
                if connection:
                    cli('disconnect', '--connection', connection)
            finally:
                server.shutdown()


if __name__ == '__main__':
    main()
