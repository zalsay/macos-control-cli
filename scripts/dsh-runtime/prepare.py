#!/usr/bin/env python3
"""Create review-only DSH image and deterministic inventory; no trust anchor is created."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile


def digest_file(path):
    h = hashlib.sha256()
    before = path.lstat()
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        opened = os.fstat(fd)
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            raise ValueError('file replaced while opening')
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                h.update(chunk)
        after = os.fstat(fd)
        current = path.lstat()
        identity = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_nlink, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        if identity(before) != identity(after) or identity(after) != identity(current):
            raise ValueError('file changed while reading')
    finally:
        os.close(fd)
    return h.hexdigest()


def validate_link(root, parent, target):
    pending = target.split('/')
    parts = list(parent.parts)
    if parent == Path('.'):
        parts = []
    links = 0
    while pending:
        part = pending.pop(0)
        if part in ('', '.'):
            continue
        if part == '..':
            if not parts:
                raise ValueError('link crosses root')
            parts.pop()
            continue
        candidate = root.joinpath(*parts, part)
        try:
            s = candidate.lstat()
        except OSError as exc:
            raise ValueError('dangling link') from exc
        if stat.S_ISLNK(s.st_mode):
            links += 1
            if links > 40:
                raise ValueError('cyclic link')
            dest = os.readlink(candidate)
            if not dest or os.path.isabs(dest):
                raise ValueError('absolute or empty link')
            pending = dest.split('/') + pending
        else:
            if pending and not stat.S_ISDIR(s.st_mode):
                raise ValueError('link traverses non-directory')
            parts.append(part)


def manifest_bytes(root):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('invalid root')
    entries = []
    def walk(directory, rel):
        before = directory.lstat()
        mode = stat.S_IMODE(before.st_mode)
        if not stat.S_ISDIR(before.st_mode) or mode & 0o7022:
            raise ValueError('unsafe directory')
        entries.append({'path': rel or '.', 'type': 'directory', 'mode': mode})
        with os.scandir(directory) as it:
            names = sorted(entry.name for entry in it)
        for name in names:
            if name in ('.', '..') or '/' in name or '\x00' in name:
                raise ValueError('invalid path')
            p = directory / name
            relative = f'{rel}/{name}' if rel else name
            s = p.lstat()
            mode = stat.S_IMODE(s.st_mode)
            if stat.S_ISLNK(s.st_mode):
                target = os.readlink(p)
                if not target or os.path.isabs(target):
                    raise ValueError('absolute or empty link')
                validate_link(root, Path(rel) if rel else Path('.'), target)
                if p.lstat().st_ino != s.st_ino or os.readlink(p) != target:
                    raise ValueError('link changed')
                entries.append({'path': relative, 'type': 'symlink', 'target': target, 'mode': mode})
            elif stat.S_ISDIR(s.st_mode):
                walk(p, relative)
            elif stat.S_ISREG(s.st_mode):
                if s.st_nlink != 1 or mode & 0o7022:
                    raise ValueError('unsafe file')
                entries.append({'path': relative, 'type': 'file', 'mode': mode, 'size': s.st_size, 'sha256': digest_file(p)})
            else:
                raise ValueError('special file')
        after = directory.lstat()
        signature = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_mtime_ns, s.st_ctime_ns)
        if signature(before) != signature(after):
            raise ValueError('directory changed while reading')
    walk(root, '')
    return (json.dumps({'format': 1, 'entries': entries}, ensure_ascii=True, sort_keys=True, separators=(',', ':')) + '\n').encode()


def verify_tree(root, expected):
    if manifest_bytes(root) != expected:
        raise ValueError('tree differs from manifest')


def verify_image(image, mount, expected):
    mount.mkdir(mode=0o700)
    attached = False
    try:
        result = subprocess.run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', str(mount), '-plist', str(image)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            raise RuntimeError(f'image attach failed; preserve temporary directory {mount.parent}')
        attached = True
        data = plistlib.loads(result.stdout)
        points = [os.path.realpath(e['mount-point']) for e in data['system-entities'] if e.get('mount-point')]
        if points != [os.path.realpath(mount)]:
            raise RuntimeError('unexpected image mountpoint')
        verify_tree(mount, expected)
    finally:
        if attached:
            result = subprocess.run(['/usr/bin/hdiutil', 'detach', str(mount)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode:
                raise RuntimeError(f'image detach failed; preserve temporary directory {mount.parent}')


def prepare(dsh, node, output):
    dsh, node, output = map(Path, (dsh, node, output))
    if not all(p.is_absolute() for p in (dsh, node, output)):
        raise ValueError('all paths must be absolute')
    if output.exists() or output.is_symlink() or not output.parent.is_dir():
        raise ValueError('output must be new and its parent must exist')
    if node.is_symlink() or not node.is_file() or node.stat().st_nlink != 1 or node.stat().st_mode & 0o7022 or not node.stat().st_mode & 0o111:
        raise ValueError('node must be a safe regular file')
    # Reject output nested in the source: never alter the source while copying.
    if output.resolve().is_relative_to(dsh.resolve(strict=True)):
        raise ValueError('output inside source')
    before = manifest_bytes(dsh)
    node_hash = digest_file(node)
    tmp = Path(tempfile.mkdtemp(prefix='safarier-dsh-prepare-'))
    cleanup = True
    try:
        tree = tmp / 'runtime'
        tree.mkdir(mode=0o700)
        shutil.copytree(dsh, tree / 'dsh', symlinks=True)
        (tree / 'node').mkdir(mode=0o700)
        shutil.copy2(node, tree / 'node' / 'node', follow_symlinks=False)
        verify_tree(dsh, before)
        verify_tree(tree / 'dsh', before)
        if digest_file(node) != node_hash or digest_file(tree / 'node/node') != node_hash:
            raise ValueError('node changed while copying')
        manifest = manifest_bytes(tree)
        image = tmp / 'runtime.dmg'
        subprocess.run(['/usr/bin/hdiutil', 'create', '-quiet', '-fs', 'HFSX', '-format', 'UDZO', '-volname', 'SafarierDSH', '-srcfolder', str(tree), str(image)], check=True)
        verify_tree(tree, manifest)
        try:
            verify_image(image, tmp / 'mount', manifest)
        except RuntimeError as exc:
            if str(exc).startswith(('image detach failed', 'image attach failed')):
                cleanup = False
            raise
        image_hash = digest_file(image)
        output.mkdir(mode=0o700)
        (output / 'INCOMPLETE').write_text('Review output is incomplete until this marker is removed.\n')
        (output / 'manifest.json').write_bytes(manifest)
        shutil.copyfile(image, output / 'runtime.dmg')
        if digest_file(output / 'runtime.dmg') != image_hash:
            raise ValueError('output image changed while copying')
        result = {'manifest_sha256': hashlib.sha256(manifest).hexdigest(), 'image_sha256': image_hash, 'node_sha256': node_hash, 'status': 'unreviewed'}
        (output / 'review.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
        (output / 'INCOMPLETE').unlink()
        return result
    finally:
        if cleanup:
            shutil.rmtree(tmp)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dsh', required=True)
    parser.add_argument('--node', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.dsh, args.node, args.output), indent=2, sort_keys=True))

if __name__ == '__main__':
    main()
