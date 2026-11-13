import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import prepare
import verify

class OfflineBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.tree = self.root / 'tree'; self.tree.mkdir(mode=0o700)
        (self.tree / 'file').write_bytes(b'file')
        self.manifest = prepare.manifest_bytes(self.tree)
        self.artifact = self.root / 'artifact'; self.artifact.mkdir(mode=0o700)
        (self.artifact / 'manifest.json').write_bytes(self.manifest)
        (self.artifact / 'runtime.dmg').write_bytes(b'image')
        (self.artifact / 'review.json').write_text('{}')
        self.hashes = verify.ExpectedHashes(hashlib.sha256(self.manifest).hexdigest(), hashlib.sha256(b'image').hexdigest())

    def tearDown(self):
        self.tmp.cleanup()

    def run_verifier(self, artifact=None):
        with mock.patch.object(prepare, 'verify_image', side_effect=lambda image, mount, expected: prepare.verify_tree(self.tree, expected)):
            return verify.verify_artifact(artifact or self.artifact, self.hashes)

    def test_artifact_parent_symlink_rejected(self):
        link = self.root / 'alias'; link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises((ValueError, OSError)):
            self.run_verifier(link / 'artifact')

    def test_artifact_file_unsafe_mode_rejected(self):
        for name in ('manifest.json', 'runtime.dmg', 'review.json'):
            path = self.artifact / name
            original = path.stat().st_mode & 0o777
            path.chmod(0o666)
            with self.subTest(name=name), self.assertRaises((ValueError, OSError)):
                self.run_verifier()
            path.chmod(original)

    def test_macos_standard_tmp_alias_is_accepted(self):
        if sys.platform != 'darwin' or os.path.realpath('/tmp') != '/private/tmp':
            self.skipTest('macOS standard /tmp alias not available')
        with tempfile.TemporaryDirectory(dir='/tmp') as tmp:
            artifact = Path(tmp) / 'artifact'
            artifact.mkdir(mode=0o700)
            for name in ('manifest.json', 'runtime.dmg', 'review.json'):
                (artifact/name).write_bytes((self.artifact/name).read_bytes())
            self.run_verifier(artifact)

    def test_artifact_file_wrong_owner_rejected(self):
        original = os.fstat
        def foreign(fd):
            s = original(fd)
            fields = ('st_dev', 'st_ino', 'st_mode', 'st_nlink', 'st_size', 'st_mtime_ns', 'st_ctime_ns', 'st_uid')
            values = {name: getattr(s, name) for name in fields}
            values['st_uid'] += 1
            return SimpleNamespace(**values)
        with mock.patch.object(verify.os, 'fstat', side_effect=foreign):
            with self.assertRaises((ValueError, OSError)):
                self.run_verifier()

    def test_path_replaced_during_copy_rejected(self):
        source = self.artifact / 'runtime.dmg'
        replacement = self.root / 'replacement'; replacement.write_bytes(b'image')
        original = os.fstat
        calls = 0
        def replace_after_read(fd):
            nonlocal calls
            calls += 1
            s = original(fd)
            if calls == 2: os.replace(replacement, source)
            return s
        with mock.patch.object(verify.os, 'fstat', side_effect=replace_after_read):
            with self.assertRaises((ValueError, OSError)):
                verify.checked_copy(source, self.root / 'copied')

    def test_in_place_change_during_copy_rejected(self):
        source = self.artifact / 'runtime.dmg'
        original = os.fstat
        calls = 0
        def mutate_after_read(fd):
            nonlocal calls
            calls += 1
            if calls == 2: source.write_bytes(b'changed')
            return original(fd)
        with mock.patch.object(verify.os, 'fstat', side_effect=mutate_after_read):
            with self.assertRaises((ValueError, OSError)):
                verify.checked_copy(source, self.root / 'copied')

    def test_failed_attach_retains_private_directory_and_aborts(self):
        private = self.root / 'private'; private.mkdir(mode=0o700)
        failure = subprocess.CompletedProcess([], 1, b'', b'fixture')
        with mock.patch.object(verify.tempfile, 'mkdtemp', return_value=str(private)), mock.patch.object(prepare.subprocess, 'run', return_value=failure):
            with self.assertRaisesRegex(RuntimeError, 'attach failed'):
                verify.verify_artifact(self.artifact, self.hashes)
        self.assertTrue((private / 'runtime.dmg').is_file())
        self.assertTrue((private / 'mount').is_dir())

    def test_failed_detach_retains_private_directory_and_aborts(self):
        private = self.root / 'private'; private.mkdir(mode=0o700)
        plist = plistlib.dumps({'system-entities': [{'mount-point': str(private / 'mount')}]})
        responses = [subprocess.CompletedProcess([], 0, plist, b''), subprocess.CompletedProcess([], 1, b'', b'fixture')]
        with mock.patch.object(verify.tempfile, 'mkdtemp', return_value=str(private)), mock.patch.object(prepare.subprocess, 'run', side_effect=responses), mock.patch.object(prepare, 'verify_tree'):
            with self.assertRaisesRegex(RuntimeError, 'detach failed'):
                verify.verify_artifact(self.artifact, self.hashes)
        self.assertTrue((private / 'runtime.dmg').is_file())
        self.assertTrue((private / 'mount').is_dir())

if __name__ == '__main__': unittest.main()
