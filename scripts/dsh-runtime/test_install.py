import hashlib
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import install
import prepare
import verify

class InstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.artifact = root / 'artifact'; self.artifact.mkdir(mode=0o700)
        (self.artifact/'manifest.json').write_bytes(b'manifest')
        (self.artifact/'runtime.dmg').write_bytes(b'image')
        (self.artifact/'review.json').write_text('{"image_sha256":"forged"}')
        self.versions = root/'versions'; self.versions.mkdir(mode=0o700)
        self.anchor = install.RuntimeAnchor(hashlib.sha256(b'manifest').hexdigest(), hashlib.sha256(b'image').hexdigest(), '24.19.0')
    def tearDown(self): self.tmp.cleanup()
    def test_reviewed_candidate_anchor_is_fixed(self):
        self.assertEqual(install.required_anchor(), install.RuntimeAnchor(
            '34e57a58a7674ebe656b249ab9f3bd2ca0cef45bdb9eacbec88592a8a0ec57de',
            '8a4c22bb334a3c307f8494cda029b80cd6a49545789e5e6087b878eef464baeb',
            '24.19.0'))
    def test_reviewed_anchor_rejects_different_artifact_before_publish(self):
        with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
            install.install_reviewed(self.artifact, self.versions)
        self.assertEqual(list(self.versions.iterdir()), [])
    def test_cli_explicit_versions_root_with_matching_fixture_anchor(self):
        def check(path, anchor):
            self.assertEqual(anchor, self.anchor.hashes)
            self.assertEqual((path/'manifest.json').read_bytes(), b'manifest')
            self.assertEqual((path/'runtime.dmg').read_bytes(), b'image')
        with mock.patch.object(install, 'REVIEWED_ANCHOR', self.anchor), mock.patch.object(verify, 'verify_artifact', side_effect=check):
            install.main(['install', '--artifact', str(self.artifact), '--versions-root', str(self.versions)])
        self.assertTrue((self.versions/self.anchor.image_sha256/'runtime.dmg').is_file())
    def test_no_reviewed_anchor_fails_closed(self):
        with mock.patch.object(install, 'REVIEWED_ANCHOR', None):
            with self.assertRaisesRegex(ValueError, 'anchor'): install.install_reviewed(self.artifact, self.versions)
        self.assertEqual(list(self.versions.iterdir()), [])
    def test_install_verifies_source_and_copy_and_no_overwrite(self):
        checked = []
        def check(path, anchor):
            checked.append((path, anchor))
            self.assertEqual((path/'manifest.json').read_bytes(), b'manifest')
            self.assertEqual((path/'runtime.dmg').read_bytes(), b'image')
        with mock.patch.object(install, 'REVIEWED_ANCHOR', self.anchor), mock.patch.object(verify, 'verify_artifact', side_effect=check):
            target = install.install_reviewed(self.artifact, self.versions)
            self.assertEqual(target.name, self.anchor.image_sha256)
            self.assertEqual(len(checked), 2)
            self.assertEqual((target/'review.json').read_text(), '{}\n')
            self.assertEqual(install.install_reviewed(self.artifact, self.versions), target)
            self.assertEqual(len(checked), 4)
            (target/'runtime.dmg').write_bytes(b'changed')
            with mock.patch.object(verify, 'verify_artifact', side_effect=ValueError('mismatch')):
                with self.assertRaises(ValueError): install.install_reviewed(self.artifact, self.versions)
            self.assertEqual((target/'runtime.dmg').read_bytes(), b'changed')
    def test_copy_mismatch_never_publishes(self):
        for name in ('manifest.json', 'runtime.dmg'):
            path = self.artifact/name; original = path.read_bytes(); path.write_bytes(b'tampered')
            with self.subTest(name=name), mock.patch.object(install, 'REVIEWED_ANCHOR', self.anchor), mock.patch.object(verify, 'verify_artifact'):
                with self.assertRaises(ValueError): install.install_reviewed(self.artifact, self.versions)
            self.assertEqual(list(self.versions.iterdir()), [])
            path.write_bytes(original)
    def test_unsafe_private_root_rejected(self):
        self.versions.chmod(0o777)
        with mock.patch.object(install, 'REVIEWED_ANCHOR', self.anchor):
            with self.assertRaises(ValueError): install.install_reviewed(self.artifact, self.versions)
    def test_verify_installed_needs_source_anchor(self):
        with mock.patch.object(install, 'REVIEWED_ANCHOR', None):
            with self.assertRaises(ValueError): install.verify_installed(self.artifact)
    def test_small_real_image_install_and_verify(self):
        root = Path(self.tmp.name)
        source = root/'dsh'; source.mkdir(mode=0o700)
        (source/'entry.js').write_text('module.exports = 1;\n')
        node = root/'node'; node.write_text('#!/bin/sh\nexit 0\n'); node.chmod(0o755)
        result = prepare.prepare(source, node, root/'prepared')
        anchor = install.RuntimeAnchor(result['manifest_sha256'], result['image_sha256'], '24.19.0')
        with mock.patch.object(install, 'REVIEWED_ANCHOR', anchor):
            target = install.install_reviewed(root/'prepared', self.versions)
            evidence = install.verify_installed(target)
            self.assertEqual(evidence.image_sha256, anchor.image_sha256)
    def test_concurrent_exclusive_publish_reuses_verified_winner(self):
        barrier = threading.Barrier(2)
        original = install.publish_exclusive
        def synchronized(source, target):
            barrier.wait(timeout=5)
            return original(source, target)
        def check(path, anchor):
            self.assertEqual((path/'manifest.json').read_bytes(), b'manifest')
            self.assertEqual((path/'runtime.dmg').read_bytes(), b'image')
        result, errors = [], []
        def worker():
            try: result.append(install.install_reviewed(self.artifact, self.versions))
            except Exception as exc: errors.append(exc)
        with mock.patch.object(install, 'REVIEWED_ANCHOR', self.anchor), mock.patch.object(verify, 'verify_artifact', side_effect=check), mock.patch.object(install, 'publish_exclusive', side_effect=synchronized):
            threads = [threading.Thread(target=worker) for _ in range(2)]
            for thread in threads: thread.start()
            for thread in threads: thread.join(timeout=10)
        self.assertEqual(errors, [])
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0], result[1])
        self.assertEqual([p.name for p in self.versions.iterdir()], [self.anchor.image_sha256])
    def test_cli_fail_closed_without_source_anchor(self):
        with mock.patch.object(install, 'REVIEWED_ANCHOR', None):
            with self.assertRaisesRegex(ValueError, 'anchor'):
                install.main(['install', '--artifact', str(self.artifact), '--versions-root', str(self.versions)])

if __name__ == '__main__': unittest.main()
