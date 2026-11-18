import json
import os
import pathlib
import subprocess
import tempfile
import unittest

BIN = pathlib.Path(os.environ.get('MBC_BINARY', 'target/mbc/macos-ble-control')).resolve()
DEVICE = 'CD579B26-0054-4C51-9E71-04FA92234E60'
OTHER = '6DBC5AAA-2236-45B1-BEF2-02979B2515B0'

class DeviceSelection(unittest.TestCase):
    def test_saved_device_and_explicit_override(self):
        with tempfile.TemporaryDirectory() as directory:
            cfg = pathlib.Path(directory, 'ble-device.json')
            env = dict(os.environ, MCC_CONFIG_DIR=directory)
            def run(*args):
                return subprocess.run([BIN, *args, '--dry-run', '--status'], env=env, capture_output=True, text=True)
            self.assertEqual(json.loads(run().stdout)['device'], 'pilot-2')
            cfg.write_text(json.dumps({'id': DEVICE, 'name': 'ESP Test'}))
            cfg.chmod(0o600)
            self.assertEqual(json.loads(run().stdout)['deviceId'], DEVICE)
            self.assertEqual(json.loads(run('--device', OTHER).stdout)['deviceId'], OTHER)
            matching = run('--host-controlled', '--expected-device', DEVICE)
            self.assertEqual(json.loads(matching.stdout)['deviceSelection'], DEVICE)
            mismatch = run('--host-controlled', '--expected-device', OTHER)
            self.assertNotEqual(mismatch.returncode, 0)
            self.assertNotIn('Connected', mismatch.stdout)

            cfg.write_text('{"id":"wrong"}')
            self.assertNotEqual(run().returncode, 0)
            self.assertEqual(json.loads(run('--device', OTHER).stdout)['deviceId'], OTHER)
            cfg.write_text(json.dumps({'id': DEVICE, 'name': 'ESP Test'}))
            cfg.chmod(0o644)
            self.assertNotEqual(run().returncode, 0)

if __name__ == '__main__': unittest.main()
