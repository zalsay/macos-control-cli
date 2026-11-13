import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
import subprocess
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
spec = importlib.util.spec_from_file_location('package_release', Path(__file__).with_name('package-release.py'))
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)

class PackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); root = Path(self.tmp.name)
        self.app = root/'Safarier AI.app'; self.app.mkdir()
        self.artifact = root/'artifact'; self.artifact.mkdir()
        for name in ('manifest.json', 'runtime.dmg', 'review.json'): (self.artifact/name).write_text(name)
        self.pins = {p: 'a'*64 for p in package.build.artifact_paths_for_variant('testing')}
        self.pinfile = root/'pins.json'; self.pinfile.write_text(json.dumps(self.pins))
        self.output = root/'output'
    def tearDown(self): self.tmp.cleanup()
    def test_pin_schema_rejects_missing_extra_and_invalid(self):
        for pins in ({}, dict(self.pins, extra='a'*64), {**self.pins, next(iter(self.pins)):'wrong'}):
            self.pinfile.write_text(json.dumps(pins))
            with self.assertRaises(ValueError): package.read_pins(self.pinfile)
    def test_preflight_failure_never_creates_output(self):
        with mock.patch.object(package, 'check_app', side_effect=ValueError('bad pins')):
            with self.assertRaises(ValueError): package.package_release(self.app, self.artifact, self.pinfile, self.output)
        self.assertFalse(self.output.exists())
    def test_copy_rechecked_and_installer_hashes_recorded(self):
        with mock.patch.object(package, 'check_app') as appcheck, mock.patch.object(package.verify, 'verify_artifact') as artifactcheck:
            package.package_release(self.app, self.artifact, self.pinfile, self.output)
        self.assertEqual(appcheck.call_count, 2); self.assertEqual(artifactcheck.call_count, 2)
        evidence=json.loads((self.output/'evidence.json').read_text())
        self.assertEqual(evidence['app_pins'], self.pins)
        self.assertEqual(set(evidence['installer_sha256']), {'install.py','prepare.py','verify.py'})
        self.assertIn('DSHRuntime', (self.output/'INSTALL.txt').read_text())
        self.assertFalse((self.output/'INCOMPLETE').exists())
    def test_output_exists_or_copy_check_failure_keeps_incomplete(self):
        self.output.mkdir(); (self.output/'keep').write_text('untouched')
        with self.assertRaises(FileExistsError): package.package_release(self.app, self.artifact, self.pinfile, self.output)
        self.assertEqual((self.output/'keep').read_text(), 'untouched')
        other=self.output.parent/'other'
        with mock.patch.object(package, 'check_app', side_effect=[None, ValueError('changed')]), mock.patch.object(package.verify, 'verify_artifact'):
            with self.assertRaises(ValueError): package.package_release(self.app, self.artifact, self.pinfile, other)
        self.assertTrue((other/'INCOMPLETE').is_file())
        self.assertFalse((other/'evidence.json').exists())
    def test_checks_both_signatures_and_all_pins(self):
        runner = b'Identifier=sh.safarier.testing.runner\n'
        main = b'Identifier=sh.safarier.testing\n'
        results = [subprocess.CompletedProcess([], 0, b'', b''), subprocess.CompletedProcess([], 0, b'', runner),
                   subprocess.CompletedProcess([], 0, b'', b''), subprocess.CompletedProcess([], 0, b'', main)]
        with mock.patch.object(package.build, 'validate_namespace') as namespace, \
             mock.patch.object(package.build, 'validate_metadata') as metadata, \
             mock.patch.object(package.build, 'validate_resources') as resources, \
             mock.patch.object(package.build, 'sha', return_value='a'*64) as sha, \
             mock.patch.object(package.subprocess, 'run', side_effect=results) as codesign:
            package.check_app(self.app, self.pins)
        self.assertEqual(codesign.call_count, 4)
        self.assertEqual(sha.call_count, 24)
        self.assertEqual(namespace.call_count, 2)
        metadata.assert_called_once(); resources.assert_called_once()
    def test_runtime_rejection_stops_before_output(self):
        with mock.patch.object(package, 'check_app'), mock.patch.object(package.verify, 'verify_artifact', side_effect=ValueError('runtime mismatch')):
            with self.assertRaises(ValueError): package.package_release(self.app, self.artifact, self.pinfile, self.output)
        self.assertFalse(self.output.exists())
    def test_app_wrong_signing_identity_rejected(self):
        ok = subprocess.CompletedProcess([], 0, b'', b'')
        bad = subprocess.CompletedProcess([], 0, b'', b'Identifier=wrong\n')
        with mock.patch.object(package.build, 'validate_namespace'), mock.patch.object(package.build, 'validate_metadata'), \
             mock.patch.object(package.build, 'validate_resources'), mock.patch.object(package.subprocess, 'run', side_effect=[ok, bad]):
            with self.assertRaisesRegex(ValueError, 'identifier'): package.check_app(self.app, self.pins)
    def test_app_pin_mismatch_rejected(self):
        results = [subprocess.CompletedProcess([], 0, b'', b''), subprocess.CompletedProcess([], 0, b'', b'Identifier=sh.safarier.testing.runner\n'),
                   subprocess.CompletedProcess([], 0, b'', b''), subprocess.CompletedProcess([], 0, b'', b'Identifier=sh.safarier.testing\n')]
        with mock.patch.object(package.build, 'validate_namespace'), mock.patch.object(package.build, 'validate_metadata'), \
             mock.patch.object(package.build, 'validate_resources'), mock.patch.object(package.build, 'sha', return_value='b'*64), \
             mock.patch.object(package.subprocess, 'run', side_effect=results):
            with self.assertRaisesRegex(ValueError, 'pins mismatch'): package.check_app(self.app, self.pins)

if __name__ == '__main__': unittest.main()
