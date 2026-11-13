#!/usr/bin/env python3
"""Offline review only; expected SHA-256 values must come from an independent reviewer."""
import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
from dataclasses import dataclass

import prepare


@dataclass(frozen=True)
class ExpectedHashes:
    """Reviewer-supplied digests; never populate from review.json."""
    manifest_sha256: str
    image_sha256: str


@dataclass(frozen=True)
class VerificationResult:
    """Point-in-time evidence only; this is not a runtime lease or trust anchor."""
    artifact: Path
    manifest_sha256: str
    image_sha256: str
    manifest_entries: int
    symlink_entries: int


def checked_artifact_path(path):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('artifact path must be absolute without parent traversal')
    parts = list(path.parts[1:])
    # macOS exposes these root-owned system aliases by default. Accept only the
    # exact system links and check every component of their canonical targets.
    if sys.platform == 'darwin' and parts and parts[0] in ('tmp', 'var'):
        alias = Path('/') / parts[0]
        s = alias.lstat()
        if stat.S_ISLNK(s.st_mode):
            if s.st_uid != 0 or os.readlink(alias) != 'private/' + parts[0]:
                raise ValueError('unexpected system alias')
            parts.insert(0, 'private')
    current = Path('/')
    for part in parts:
        current = current / part
        if not stat.S_ISDIR(current.lstat().st_mode):
            raise ValueError('artifact path contains symlink or non-directory')
    return current


def safe_artifact_file(s):
    return stat.S_ISREG(s.st_mode) and s.st_nlink == 1 and s.st_uid == os.geteuid() and not (s.st_mode & 0o7022)


def checked_copy(source, destination, limit=None):
    before = source.lstat()
    if not safe_artifact_file(before):
        raise ValueError('artifact must be an owned, safe, independent regular file')
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        current = os.fstat(fd)
        signature = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_nlink, s.st_uid, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        if not safe_artifact_file(current) or signature(before) != signature(current) or (limit is not None and current.st_size > limit):
            raise ValueError('artifact changed or exceeds size limit')
        h = hashlib.sha256()
        with os.fdopen(fd, 'rb', closefd=False) as src, destination.open('xb') as dst:
            for chunk in iter(lambda: src.read(1024 * 1024), b''):
                h.update(chunk)
                dst.write(chunk)
        if signature(before) != signature(os.fstat(fd)) or signature(before) != signature(source.lstat()):
            raise ValueError('artifact changed during copy')
        return h.hexdigest()
    finally:
        os.close(fd)


def verify_artifact(artifact, manifest_sha256, image_sha256=None):
    expected_hashes = manifest_sha256 if isinstance(manifest_sha256, ExpectedHashes) else ExpectedHashes(manifest_sha256, image_sha256)
    if any(not re.fullmatch(r'[0-9a-f]{64}', value) for value in (expected_hashes.manifest_sha256, expected_hashes.image_sha256)):
        raise ValueError('expected hashes must be lowercase SHA-256')
    artifact = checked_artifact_path(artifact)
    if {entry.name for entry in os.scandir(artifact)} != {'manifest.json', 'runtime.dmg', 'review.json'}:
        raise ValueError('unexpected artifact namespace')
    review = artifact / 'review.json'
    review_stat = review.lstat()
    if not safe_artifact_file(review_stat):
        raise ValueError('invalid review metadata file')
    tmp = Path(tempfile.mkdtemp(prefix='safarier-dsh-verify-'))
    cleanup = True
    try:
        manifest = tmp / 'manifest.json'
        image = tmp / 'runtime.dmg'
        actual_manifest = checked_copy(artifact / 'manifest.json', manifest, limit=64 * 1024 * 1024)
        if not hmac.compare_digest(actual_manifest, expected_hashes.manifest_sha256):
            raise ValueError('manifest SHA-256 mismatch')
        actual_image = checked_copy(artifact / 'runtime.dmg', image)
        if not hmac.compare_digest(actual_image, expected_hashes.image_sha256):
            raise ValueError('image SHA-256 mismatch')
        expected = manifest.read_bytes()
        parsed = json.loads(expected)
        try:
            prepare.verify_image(image, tmp / 'mount', expected)
        except RuntimeError as exc:
            if str(exc).startswith(('image detach failed', 'image attach failed')):
                cleanup = False
            raise
        if not hmac.compare_digest(prepare.digest_file(image), expected_hashes.image_sha256):
            raise ValueError('image changed during verification')
        entries = parsed.get('entries')
        if parsed.get('format') != 1 or not isinstance(entries, list):
            raise ValueError('invalid canonical manifest')
        return VerificationResult(
            artifact=artifact,
            manifest_sha256=expected_hashes.manifest_sha256,
            image_sha256=expected_hashes.image_sha256,
            manifest_entries=len(entries),
            symlink_entries=sum(entry.get('type') == 'symlink' for entry in entries),
        )
    finally:
        if cleanup:
            shutil.rmtree(tmp)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact', required=True, type=Path)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--image-sha256', required=True)
    args = parser.parse_args()
    result = verify_artifact(args.artifact, ExpectedHashes(args.manifest_sha256, args.image_sha256))
    print(f'Offline artifact verification passed: {result.manifest_entries} entries, {result.symlink_entries} symlinks; no runtime lease or production binding established.')

if __name__ == '__main__':
    main()
