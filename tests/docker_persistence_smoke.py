#!/usr/bin/env python3
"""Run with MCC_PERSIST_PHASE=set, restart the container, then phase=check."""
import http.server
import json
import os
import subprocess
import threading

phase = os.environ['MCC_PERSIST_PHASE']
assert phase in ('set', 'check')
retained = threading.Event()
loaded = threading.Event()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if 'mcc_container_persist=yes' in self.headers.get('Cookie', ''):
            retained.set()
        self.send_response(200)
        if phase == 'set':
            self.send_header('Set-Cookie', 'mcc_container_persist=yes; Max-Age=3600; Path=/; SameSite=Lax')
        page = b'<!doctype html><title>Container persistence test</title><h1>Persistent profile</h1>'
        self.send_header('Content-Length', str(len(page)))
        self.end_headers()
        self.wfile.write(page)
        loaded.set()

    def log_message(self, *_):
        pass


def cli(*args):
    result = subprocess.run(['mcc', *map(str, args)], capture_output=True, text=True, timeout=45)
    value = json.loads(result.stdout)
    assert result.returncode == 0 and value['ok'], value
    return value


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
connection = cli('firefox', 'start', '--profile', 'container-persistence-smoke',
                 '--url', f'http://127.0.0.1:{server.server_port}/')['connectionId']
try:
    assert loaded.wait(5), 'fixture page did not load'
    cli('observe', '--connection', connection)
    if phase == 'check':
        assert retained.wait(5), 'profile cookie did not survive container restart'
        print('PASS: cookie survived container restart with an open Firefox session')
    else:
        print('PASS: persistent cookie set; leave the owned Firefox open for container stop')
finally:
    if phase == 'check':
        cli('disconnect', '--connection', connection)
    server.shutdown()
