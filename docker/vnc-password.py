#!/usr/bin/env python3
"""Create/check a private x11vnc password file, without command-line secrets."""
import getpass
import os
from pathlib import Path
import stat
import sys


def validate(value):
    if len(value) != 8 or any(ord(char) < 33 or ord(char) > 126 for char in value):
        raise ValueError('VNC password must contain exactly 8 printable ASCII characters (no spaces).')


def check(path):
    # O_NOFOLLOW also protects the open after checking metadata.
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as stream:
        metadata = os.fstat(stream.fileno())
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
                or metadata.st_nlink != 1 or metadata.st_mode & 0o077 or metadata.st_size > 9):
            raise ValueError('VNC password file must be a private regular file owned by the desktop user (mode 0600).')
        raw = stream.read(10)
    value = raw.removesuffix(b'\n').decode('ascii')
    validate(value)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--check':
        check(Path(sys.argv[2]))
        return
    if len(sys.argv) != 1:
        raise ValueError('Usage: mcc-vnc-password [--check FILE]')
    path = Path(os.environ.get('MCC_VNC_PASSWORD_FILE', '/home/mcc/.secrets/vnc-password'))
    if not sys.stdin.isatty():
        raise ValueError('Password setup needs an interactive terminal; use docker compose run --rm -it.')
    password = getpass.getpass('VNC password (exactly 8 printable ASCII characters): ')
    validate(password)
    if password != getpass.getpass('Repeat VNC password: '):
        raise ValueError('VNC passwords do not match.')
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name('.vnc-password-new')
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(descriptor, 'w', encoding='ascii') as stream:
            stream.write(password + '\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
    print('Private VNC password file saved. Restart the desktop to use the new password.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, UnicodeError, ValueError) as error:
        if isinstance(error, OSError):
            message = 'Cannot read/write the private VNC password file; run password setup and check ownership.'
        elif isinstance(error, UnicodeError):
            message = 'VNC password file must contain printable ASCII.'
        else:
            message = str(error)
        print(message, file=sys.stderr)
        sys.exit(1)
