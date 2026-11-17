#!/usr/bin/env python3
"""Live, loopback-only regression for a registered page redirect after didFinish.

Uses the installed signed app, a fresh ephemeral profile and a private daemon.
Never navigates or closes an existing user profile. Evidence directory must be new.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--background-app', default='com.openai.codex', help='App to activate so the fixture browser stays in background')
    args = parser.parse_args()
    app = args.app.resolve()
    executable = app / 'Contents/MacOS/Safarier AI'
    assert executable.is_file()
    evidence = args.evidence.resolve()
    evidence.mkdir(mode=0o700)
    runtime = Path(tempfile.mkdtemp(prefix='sfr-', dir=Path.home()))
    records = []
    profile = None
    connection = None
    daemon_started = False
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            (evidence / 'requests.json').write_text(json.dumps(requests, indent=2))
            if self.path == '/redirect':
                body = '''<!doctype html><h1>REDIRECT SOURCE</h1><script>
                addEventListener('load', () => setTimeout(() => location.replace('/final'), 80));
                </script>'''
            elif self.path.startswith('/final'):
                body = '''<!doctype html><h1>REDIRECT FINISHED</h1><script>
                addEventListener('load', () => {
                  setTimeout(() => history.replaceState(null, '', '/final?replace=done'), 300);
                  setTimeout(() => history.pushState(null, '', '/final?push=done'), 600);
                });</script>'''
            else:
                body = '<!doctype html><h1>LOCAL SOURCE</h1>'
            data = body.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *unused):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'

    def run(label, argv, *, json_reply=True, timeout=80):
        started = time.monotonic()
        result = subprocess.run([str(executable)] + argv, capture_output=True, timeout=timeout)
        (evidence / (label + '.stdout')).write_bytes(result.stdout)
        (evidence / (label + '.stderr')).write_bytes(result.stderr)
        record = dict(label=label, exitCode=result.returncode, elapsed=round(time.monotonic() - started, 3))
        if json_reply and result.stdout:
            record['reply'] = json.loads(result.stdout)
        records.append(record)
        (evidence / 'summary.json').write_text(json.dumps(records, indent=2) + '\n')
        print(label, record['elapsed'], 'seconds', result.returncode, flush=True)
        return result, record.get('reply')

    control = ['control', '--app', str(app), '--runtime', str(runtime)]
    try:
        result, _ = run('create', ['profile', 'create', '--name', 'Redirect regression ' + uuid.uuid4().hex[:8],
                                 '--mode', 'ephemeral', '--lang', 'system', '--tz', 'system', '--url', base + '/source'], json_reply=False)
        assert result.returncode == 0
        profile = str(uuid.UUID(result.stdout.decode().strip())).upper()
        (evidence / 'profile.txt').write_text(profile + '\n')
        log = Path.home() / 'Library/Application Support/Safarier AI/logs' / (profile + '.log')
        result, _ = run('launch', ['launch', profile], json_reply=False)
        assert result.returncode == 0
        focus = evidence / 'activate-host.swift'
        focus.write_text('''import AppKit
let target = CommandLine.arguments.last!
let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == target }
guard apps.count == 1, apps[0].activate(options: []) else { exit(1) }
''')
        subprocess.run(['/usr/bin/swift', str(focus), args.background_app], check=True, timeout=15)
        until = time.monotonic() + 25
        while time.monotonic() < until:
            if log.exists() and 'REGISTERED_PAGE_DIAG phase=didFinish' in log.read_text():
                break
            time.sleep(.1)
        else:
            raise AssertionError('Fixture source did not finish')
        result, _ = run('daemon-start', control + ['daemon', 'start'])
        assert result.returncode == 0
        daemon_started = True
        result, reply = run('connect', control + ['connect', '--profile', profile])
        assert result.returncode == 0, reply
        connection = reply['connection']
        result, reply = run('navigate', control + ['navigate', '--connection', connection, '--url', base + '/redirect'])
        assert result.returncode == 0 and reply.get('navigationSubmitted') is True and reply.get('effectVerified') is False, reply
        time.sleep(1)
        result, reply = run('state', control + ['state', '--connection', connection])
        assert result.returncode == 0 and reply['state']['url'] == base + '/final?push=done' and not reply['state']['loading'], reply
        result, reply = run('observe', control + ['observe', '--connection', connection])
        assert result.returncode == 0, reply
        shutil.copy2(reply['screenshotPath'], evidence / 'final.png')
        result, reply = run('release', control + ['release', '--connection', connection])
        assert result.returncode == 0, reply
        assert all(reply['controlReleased'][key] for key in ('inputReleased', 'artifactsCleaned', 'browserRetained', 'manualInteractionEnabled')), reply
        connection = None
        assert requests.count('/redirect') == 1 and requests.count('/final') == 1, requests
        print('PASS: one submission, page redirect, idle History API, observe and release', flush=True)
    finally:
        if connection:
            run('cleanup-release', control + ['release', '--connection', connection])
        if daemon_started:
            run('daemon-stop', control + ['daemon', 'stop'])
        if profile:
            log = Path.home() / 'Library/Application Support/Safarier AI/logs' / (profile + '.log')
            if log.exists():
                shutil.copy2(log, evidence / 'browser.log')
            # Only this test's newly created ephemeral browser, never other apps.
            processes = subprocess.run(['/bin/ps', '-ww', '-axo', 'pid=,args='], check=True, capture_output=True, text=True).stdout
            owned = []
            browser = str(app / 'Contents/Helpers/Safarier AI Browser.app/Contents/MacOS/Safarier AI Browser')
            for line in processes.splitlines():
                fields = line.strip().split(None, 1)
                if len(fields) == 2 and fields[1].startswith(browser + ' run --profile ' + profile + ' '):
                    owned.append(int(fields[0]))
            for pid in owned:
                os.kill(pid, signal.SIGTERM)
            until = time.monotonic() + 10
            while owned and time.monotonic() < until:
                for pid in list(owned):
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        owned.remove(pid)
                time.sleep(.1)
            assert not owned, 'Fixture browser still running; preserve profile for diagnosis'
            run('delete', ['profile', 'delete', profile, '--purge-data'], json_reply=False)
        server.shutdown()
        server.server_close()
        # Keep the private runtime if cleanup did not remove its socket.
        if not (runtime / 'control.sock').exists():
            runtime.rmdir()


if __name__ == '__main__':
    main()
