#!/usr/bin/env python3
"""Exercise the actual password-file boundary without a running desktop."""
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name('vnc-password.py')


class PrivatePasswordFile(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = pathlib.Path(self.directory.name) / 'password'

    def check(self):
        return subprocess.run(['python3', str(SCRIPT), '--check', str(self.path)],
                              capture_output=True, text=True)

    def write(self, text, mode=0o600):
        self.path.write_text(text)
        self.path.chmod(mode)

    def test_valid_private_password_is_not_printed(self):
        self.write('aB3$xy9!\n')
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout + result.stderr, '')

    def test_missing_password_requires_explicit_setup(self):
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn('password file', result.stderr)

    def test_public_password_file_is_rejected_without_echo(self):
        self.write('aB3$xy9!\n', 0o644)
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('aB3$xy9!', result.stdout + result.stderr)

    def test_symlink_is_rejected(self):
        target = self.path.with_name('target')
        target.write_text('aB3$xy9!\n')
        target.chmod(0o600)
        self.path.symlink_to(target)
        self.assertEqual(self.check().returncode, 1)

    def test_vnc_password_is_exactly_eight_printable_ascii_bytes(self):
        for value in ('', 'short', 'ninechars', 'aB3$xy9!\nextra', '中文密码1234'):
            with self.subTest(value=value):
                self.write(value)
                self.assertEqual(self.check().returncode, 1)


if __name__ == '__main__':
    unittest.main()
