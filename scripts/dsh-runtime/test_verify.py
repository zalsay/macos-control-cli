import hashlib
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import prepare
spec = importlib.util.spec_from_file_location('offline_verify', Path(__file__).with_name('verify.py'))
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)

class OfflineVerificationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.tree = root / 'tree'; self.tree.mkdir(mode=0o700)
        (self.tree / 'module.js').write_text('module.exports=1;\n')
        (self.tree / 'link').symlink_to('module.js')
        self.artifact = root / 'artifact'; self.artifact.mkdir()
        self.manifest = prepare.manifest_bytes(self.tree)
        (self.artifact / 'manifest.json').write_bytes(self.manifest)
        (self.artifact / 'runtime.dmg').write_bytes(b'original image')
        (self.artifact / 'review.json').write_text('{"manifest_sha256":"not trusted"}')
        self.mhash = hashlib.sha256(self.manifest).hexdigest()
        self.ihash = hashlib.sha256(b'original image').hexdigest()
    def tearDown(self): self.tmp.cleanup()
    def check(self):
        with mock.patch.object(verify.prepare, 'verify_image', side_effect=lambda image, mount, expected: prepare.verify_tree(self.tree, expected)):
            return verify.verify_artifact(self.artifact, verify.ExpectedHashes(self.mhash, self.ihash))
    def test_valid_and_untrusted_review_ignored(self):
        result = self.check()
        self.assertEqual((result.manifest_entries, result.symlink_entries), (3, 1))
    def test_extra_artifact_file_rejected(self):
        (self.artifact/'extra').write_text('extra')
        with self.assertRaisesRegex(ValueError, 'namespace'): self.check()
    def test_manifest_and_image_tamper_fail_before_mount(self):
        for name in ('manifest.json', 'runtime.dmg'):
            path = self.artifact / name; old = path.read_bytes(); path.write_bytes(old+b'x')
            with mock.patch.object(verify.prepare, 'verify_image') as mount:
                with self.assertRaises(ValueError): verify.verify_artifact(self.artifact, self.mhash, self.ihash)
                mount.assert_not_called()
            path.write_bytes(old)
    def test_extra_file_and_content_tamper_fail(self):
        extra=self.tree/'extra'; extra.write_text('x')
        with self.assertRaises(ValueError): self.check()
        extra.unlink(); (self.tree/'module.js').write_text('modified')
        with self.assertRaises(ValueError): self.check()
    def test_escaping_link_and_mode_fail(self):
        (self.tree/'link').unlink(); (self.tree/'link').symlink_to('../escape')
        with self.assertRaises(ValueError): self.check()
        (self.tree/'link').unlink(); (self.tree/'link').symlink_to('module.js')
        (self.tree/'module.js').chmod(0o755)
        with self.assertRaises(ValueError): self.check()
    def test_invalid_hash_and_symlink_artifact_fail(self):
        with self.assertRaises(ValueError): verify.verify_artifact(self.artifact, 'x', self.ihash)
        (self.artifact/'runtime.dmg').unlink(); (self.artifact/'runtime.dmg').symlink_to(self.tree/'module.js')
        with self.assertRaises((ValueError, OSError)): self.check()
    def test_real_image_mount_and_detach(self):
        node = Path(self.tmp.name) / 'node'; node.write_text('#!/bin/sh\nexit 0\n'); node.chmod(0o755)
        output = Path(self.tmp.name) / 'prepared'
        result = prepare.prepare(self.tree, node, output)
        verify.verify_artifact(output, result['manifest_sha256'], result['image_sha256'])

if __name__ == '__main__': unittest.main()
