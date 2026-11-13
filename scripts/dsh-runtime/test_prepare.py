import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('dsh_prepare', Path(__file__).with_name('prepare.py'))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)

class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / 'tree'
        self.root.mkdir(mode=0o700)
        (self.root / 'modules').mkdir(mode=0o700)
        (self.root / 'modules' / 'a.js').write_text('module.exports = 1;\n')
        (self.root / 'link').symlink_to('modules/a.js')
    def tearDown(self):
        self.tmp.cleanup()
    def test_deterministic_manifest_and_exact_verification(self):
        data = prepare.manifest_bytes(self.root)
        self.assertEqual(data, prepare.manifest_bytes(self.root))
        prepare.verify_tree(self.root, data)
        (self.root / 'extra').write_text('x')
        with self.assertRaises(ValueError): prepare.verify_tree(self.root, data)
        (self.root / 'extra').unlink()
        (self.root / 'modules' / 'a.js').write_text('tampered')
        with self.assertRaises(ValueError): prepare.verify_tree(self.root, data)
    def test_reject_hardlink_and_unsafe_mode(self):
        os.link(self.root / 'modules/a.js', self.root / 'hard')
        with self.assertRaises(ValueError): prepare.manifest_bytes(self.root)
        (self.root / 'hard').unlink()
        (self.root / 'modules/a.js').chmod(0o666)
        with self.assertRaises(ValueError): prepare.manifest_bytes(self.root)
    def test_reject_symlink_escape_and_chain_escape(self):
        (self.root / 'link').unlink()
        (self.root / 'link').symlink_to('../../outside')
        with self.assertRaises(ValueError): prepare.manifest_bytes(self.root)
        (self.root / 'link').unlink()
        (self.root / 'link').symlink_to('modules/chain')
        (self.root / 'modules/chain').symlink_to('../../../outside')
        with self.assertRaises(ValueError): prepare.manifest_bytes(self.root)
        (self.root / 'modules/chain').unlink()
        (self.root / 'link').unlink()
        (self.root / 'link').symlink_to('../tree/modules/a.js')
        with self.assertRaises(ValueError): prepare.manifest_bytes(self.root)
    def test_reject_special_file_and_permissions_change(self):
        data = prepare.manifest_bytes(self.root)
        (self.root / 'modules/a.js').chmod(0o755)
        with self.assertRaises(ValueError): prepare.verify_tree(self.root, data)
        os.mkfifo(self.root / 'pipe')
        with self.assertRaises(ValueError): prepare.manifest_bytes(self.root)
    def test_failed_image_verification_does_not_publish_output(self):
        node = Path(self.tmp.name) / 'node'
        node.write_text('fixture node')
        node.chmod(0o755)
        output = Path(self.tmp.name) / 'output'
        def create_image(argv, **kwargs):
            Path(argv[-1]).write_bytes(b'fixture')
        with mock.patch.object(prepare.subprocess, 'run', side_effect=create_image), \
             mock.patch.object(prepare, 'verify_image', side_effect=ValueError('image mismatch')):
            with self.assertRaises(ValueError):
                prepare.prepare(self.root, node, output)
        self.assertFalse(output.exists())

if __name__ == '__main__': unittest.main()
