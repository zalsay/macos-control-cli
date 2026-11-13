#!/usr/bin/env python3
"""Exercise installed desktop dependencies and a headed Firefox in desktop-base."""
import os
from pathlib import Path
import secrets
import signal
import socket
import string
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

processes = []


def start(name, args):
    # Keep dependency logs private; show the failing service name, never auth data.
    log = tempfile.TemporaryFile()
    process = subprocess.Popen(args, stdout=log, stderr=log, start_new_session=True)
    processes.append((name, process, log))


def ready(name, check):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        for service, process, _ in processes:
            if process.poll() is not None:
                raise RuntimeError(f'{service} exited during {name} startup')
        try:
            if check():
                return
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(0.1)
    raise RuntimeError(f'{name} readiness timed out')


def command(*args):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          check=True, text=True).stdout


try:
    assert os.geteuid() == 1000, 'dependency smoke must run as mcc'
    os.umask(0o077)
    for relative in ('.config', '.local', '.local/share', '.local/share/mcc'):
        directory = Path(os.environ['HOME']) / relative
        assert directory.stat().st_uid == 1000 and os.access(directory, os.W_OK), f'{relative} must be owned/writable by mcc'
    runtime = Path(os.environ['XDG_RUNTIME_DIR'])
    runtime.mkdir(mode=0o700)
    authority = Path(os.environ['XAUTHORITY'])
    authority.touch(mode=0o600)
    subprocess.run(['xauth', '-f', str(authority), 'add', os.environ['DISPLAY'], '.',
                    secrets.token_hex(16)], check=True)
    os.environ['DBUS_SESSION_BUS_ADDRESS'] = f'unix:path={runtime}/dbus.sock'
    start('Xvfb', ['Xvfb', os.environ['DISPLAY'], '-screen', '0', '1440x900x24',
                   '-nolisten', 'tcp', '-auth', str(authority), '-noreset'])
    ready('Xvfb', lambda: subprocess.run(['xdpyinfo'], stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL).returncode == 0)
    start('dbus', ['dbus-daemon', '--session', '--nofork', '--nopidfile',
                  '--address=' + os.environ['DBUS_SESSION_BUS_ADDRESS']])
    start('openbox', ['openbox', '--sm-disable'])
    ready('openbox', lambda: 'window id # 0x' in command('xprop', '-root', '_NET_SUPPORTING_WM_CHECK'))
    languages = command('tesseract', '--list-langs').splitlines()
    assert 'eng' in languages and 'chi_sim' in languages, 'missing OCR language packs'
    assert '153.7.0esr' in command('/opt/firefox/firefox', '--version')
    assert not Path('/usr/local/bin/geckodriver').exists(), 'driver must not be installed'
    assert Path('/usr/share/novnc/vnc.html').is_file(), 'noVNC static page missing'
    password = ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(8))
    password_file = runtime / 'smoke-vnc-password'
    password_file.write_text(password + '\n')
    start('x11vnc', ['x11vnc', '-display', os.environ['DISPLAY'], '-auth', str(authority),
                    '-listen', '127.0.0.1', '-rfbport', '5900', '-passwdfile', str(password_file),
                    '-forever', '-shared', '-noxdamage', '-quiet'])
    def vnc_ready():
        with socket.create_connection(('127.0.0.1', 5900), timeout=1) as connection:
            banner = connection.recv(12)
            if len(banner) != 12 or not banner.startswith(b'RFB '):
                return False
            connection.sendall(b'RFB 003.008\n')
            count = connection.recv(1)[0]
            security_types = connection.recv(count)
            assert 2 in security_types and 1 not in security_types, 'VNC must require password authentication'
            return True
    ready('x11vnc', vnc_ready)
    start('noVNC', ['websockify', '--web=/usr/share/novnc', '0.0.0.0:6080', '127.0.0.1:5900'])
    def novnc_ready():
        with urllib.request.urlopen('http://127.0.0.1:6080/vnc.html', timeout=2) as response:
            return response.status == 200
    ready('noVNC', novnc_ready)
    profile = Path(os.environ['MCC_FIREFOX_PROFILE_ROOT']) / 'packaging-smoke'
    profile.mkdir(mode=0o700, parents=True)
    start('Firefox', ['/opt/firefox/firefox', '--no-remote', '--new-instance',
                      '--profile', str(profile), '--width', '1200', '--height', '820',
                      '--new-window', 'about:blank'])
    firefox = processes[-1][1]
    def visible_firefox():
        result = subprocess.run(['xdotool', 'search', '--onlyvisible', '--pid', str(firefox.pid)],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        return result.returncode == 0 and result.stdout.strip()
    ready('visible Firefox', visible_firefox)
    arguments = Path(f'/proc/{firefox.pid}/cmdline').read_bytes()
    assert b'marionette' not in arguments and b'remote-debugging' not in arguments
    assert subprocess.run(['pgrep', '-x', 'geckodriver'], stdout=subprocess.DEVNULL).returncode != 0
    print('PASS: UID1000, Xvfb/Openbox, Tesseract eng+chi_sim, authenticated VNC/noVNC, ordinary visible Firefox153.7.0esr without a driver.')
finally:
    for _, process, _ in reversed(processes):
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
    for _, process, log in reversed(processes):
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
        log.close()
