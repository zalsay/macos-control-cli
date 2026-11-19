#!/usr/bin/env python3
"""Authenticate two sequential real client processes on one local listener."""
import select
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='.sfr-peer-', dir=Path.home()) as directory:
    stage = Path(directory)
    probe = stage / 'peer'
    socket = stage / 'sock'
    native = root / 'Sources/BinderIdentity'
    subprocess.run(['xcrun', 'clang', '-I', str(native / 'include'), str(native / 'BinderIdentity.c'),
                    str(root / 'Tests/Fixtures/RegisteredReconnectPeer/Main.c'), '-framework', 'Security',
                    '-framework', 'CoreFoundation', '-lbsm', '-o', str(probe)], check=True, timeout=30)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(probe)], check=True, timeout=10)
    with subprocess.Popen([str(probe), 'serve', str(socket)], stdout=subprocess.PIPE) as server:
        try:
            assert select.select([server.stdout], [], [], 5)[0] and server.stdout.readline() == b'ready\n'
            for _ in range(2):
                subprocess.run([str(probe), 'connect', str(socket), str(server.pid)], check=True, timeout=10)
            output, _ = server.communicate(timeout=5)
            assert server.returncode == 0
            print(output.decode().strip())
        finally:
            if server.poll() is None:
                server.kill()
