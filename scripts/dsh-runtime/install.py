#!/usr/bin/env python3
"""Offline sidecar preparation only; no DSH launch or production integration."""
import ctypes
import argparse
import hmac
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
from dataclasses import dataclass

import verify

@dataclass(frozen=True)
class RuntimeAnchor:
    manifest_sha256: str
    image_sha256: str
    node_version: str

    @property
    def hashes(self):
        return verify.ExpectedHashes(self.manifest_sha256, self.image_sha256)


# Reviewed for this one candidate only. Any runtime upgrade requires independent
# review and a source change; review.json, argv and environment are never anchors.
REVIEWED_ANCHOR = RuntimeAnchor(
    manifest_sha256='34e57a58a7674ebe656b249ab9f3bd2ca0cef45bdb9eacbec88592a8a0ec57de',
    image_sha256='8a4c22bb334a3c307f8494cda029b80cd6a49545789e5e6087b878eef464baeb',
    node_version='24.19.0',
)


def required_anchor():
    anchor = REVIEWED_ANCHOR
    if not isinstance(anchor, RuntimeAnchor) or any(
        not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{64}', value) or not int(value, 16)
        for value in (anchor.manifest_sha256, anchor.image_sha256)
    ) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', anchor.node_version):
        raise ValueError('reviewed source anchor unavailable')
    return anchor


def private_directory(path):
    path = Path(path)
    if not path.is_absolute():
        raise ValueError('private versions root must be absolute')
    s = path.lstat()
    if not stat.S_ISDIR(s.st_mode) or s.st_uid != os.geteuid() or stat.S_IMODE(s.st_mode) != 0o700:
        raise ValueError('versions root must be owned private directory')
    return path


def publish_exclusive(source, destination):
    if sys.platform != 'darwin':
        raise RuntimeError('exclusive directory publication requires macOS')
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004) != 0:  # RENAME_EXCL
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))


def install_reviewed(artifact, versions_root):
    anchor = required_anchor()
    root = private_directory(versions_root)
    artifact = Path(artifact)
    target = root / anchor.image_sha256
    verify.verify_artifact(artifact, anchor.hashes)
    if target.exists() or target.is_symlink():
        verify_installed(target)
        return target
    staging = Path(tempfile.mkdtemp(prefix='.dsh-install-', dir=root))
    try:
        for name, expected, limit in (
            ('manifest.json', anchor.manifest_sha256, 64 * 1024 * 1024),
            ('runtime.dmg', anchor.image_sha256, None),
        ):
            actual = verify.checked_copy(artifact / name, staging / name, limit=limit)
            if not hmac.compare_digest(actual, expected):
                raise ValueError('copied artifact SHA-256 mismatch')
        # Placeholder only satisfies the review artifact namespace; never trusted.
        (staging / 'review.json').write_text('{}\n')
        verify.verify_artifact(staging, anchor.hashes)
        try:
            publish_exclusive(staging, target)
        except FileExistsError:
            verify_installed(target)
        return target
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def verify_installed(version_dir):
    anchor = required_anchor()
    version = Path(version_dir)
    private_directory(version.parent)
    private_directory(version)
    if version.name != anchor.image_sha256:
        raise ValueError('unexpected version directory')
    return verify.verify_artifact(version, anchor.hashes)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    install = commands.add_parser('install')
    install.add_argument('--artifact', type=Path, required=True)
    install.add_argument('--versions-root', type=Path, required=True)
    check = commands.add_parser('verify')
    check.add_argument('--version-dir', type=Path, required=True)
    args = parser.parse_args(argv)
    if args.command == 'install':
        version = install_reviewed(args.artifact, args.versions_root)
        print(f'Verified sidecar: {version} (reviewed Node {required_anchor().node_version})')
    else:
        result = verify_installed(args.version_dir)
        print(f'Verified sidecar: {result.artifact} (reviewed Node {required_anchor().node_version})')


if __name__ == '__main__':
    main()
