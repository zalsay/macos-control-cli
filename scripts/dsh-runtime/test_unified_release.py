import importlib.util
import io
from contextlib import redirect_stderr, redirect_stdout
from types import SimpleNamespace
import time
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('unified_release', Path(__file__).with_name('unified-release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ProgressTests(unittest.TestCase):
    def test_non_tty_reports_completed_stages_without_terminal_controls(self):
        stream = io.StringIO()
        progress = release.Progress(2, stream=stream)
        with progress.step('检查'): pass
        with progress.step('构建'): pass
        output = stream.getvalue()
        self.assertIn('[0/2] 检查', output)
        self.assertIn('[1/2] 构建', output)
        self.assertIn('[2/2] 完成', output)
        self.assertNotIn('\r', output)
        self.assertNotIn('%', output)

    def test_failure_names_step_without_completion(self):
        stream = io.StringIO()
        progress = release.Progress(2, stream=stream)
        with self.assertRaisesRegex(ValueError, 'bad'):
            with progress.step('构建'): raise ValueError('bad')
        self.assertIn('构建', stream.getvalue())
        self.assertIn('失败', stream.getvalue())
        self.assertNotIn('完成', stream.getvalue())

    def test_tty_long_step_reports_running_and_stops_on_exit(self):
        stream = io.StringIO()
        stream.isatty = lambda: True
        progress = release.Progress(1, stream=stream, interval=0.01)
        with progress.step('构建'):
            time.sleep(0.06)
        output = stream.getvalue()
        self.assertIn('运行中', output)
        self.assertIn('[1/1] 完成', output)
        time.sleep(0.03)
        self.assertEqual(stream.getvalue(), output)

class EntryProgressTests(unittest.TestCase):
    def run_entry(self, root, fail_build=False, fail_install=False):
        dest = root / 'dist/releases'; dest.mkdir(parents=True)
        attempt = root / 'attempt'; attempt.mkdir()
        for name in release.NAMES:
            path = dest / name
            if name.endswith('.app'): path.mkdir()
            else: path.write_text('old')
        (attempt / 'candidate-sha256.json').write_text('{}')
        (attempt / 'source-after.json').write_text('{}')
        anchor = SimpleNamespace(hashes='hashes', image_sha256='image', manifest_sha256='manifest')
        def build_main(*args):
            print('build output')
            if fail_build: raise RuntimeError('build failed')
        def package_release(app, artifact, pins, output):
            (output / 'Safarier AI.app').mkdir(parents=True)
        package = SimpleNamespace(
            install=SimpleNamespace(required_anchor=lambda: anchor),
            verify=SimpleNamespace(verify_artifact=lambda *args: None),
            build=SimpleNamespace(main=build_main, ATTEMPT=attempt, variant_layout=lambda _: {'app': 'input.app'},
                                  sha=lambda _: 'sha', source_inventory=lambda _: {}),
            package_release=package_release, read_pins=lambda _: {}, check_app=lambda *args: None)
        stderr, stdout = io.StringIO(), io.StringIO()
        with mock.patch.object(release, 'ROOT', root), mock.patch.object(release, 'package', package), \
             mock.patch.object(release, 'verify_swift_anchor', return_value='anchor'), \
             mock.patch.object(release.Path, 'home', return_value=root), \
             mock.patch.object(release, 'install_candidate', side_effect=RuntimeError('install failed') if fail_install else None), \
             mock.patch('sys.argv', ['unified-release.py']), redirect_stderr(stderr), redirect_stdout(stdout):
            if fail_build:
                with self.assertRaisesRegex(RuntimeError, 'build failed'): release.main()
            elif fail_install:
                with self.assertRaisesRegex(RuntimeError, 'release 固定候选已更新.*安装未完成'): release.main()
            else:
                release.main()
        return stderr.getvalue(), stdout.getvalue(), dest

    def test_entry_advances_only_after_steps_and_keeps_build_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            stderr, stdout, dest = self.run_entry(Path(tmp))
            for count in range(8): self.assertIn(f'[{count}/7]', stderr)
            self.assertIn('[7/7] 完成', stderr)
            self.assertIn('build output', stdout)
            self.assertTrue((dest / 'release-current.json').is_file())

    def test_entry_build_failure_does_not_publish_or_report_completion(self):
        with tempfile.TemporaryDirectory() as tmp:
            stderr, stdout, dest = self.run_entry(Path(tmp), fail_build=True)
            self.assertIn('[1/7] 构建 testing release：失败', stderr)
            self.assertNotIn('完成', stderr)
            self.assertEqual((dest / 'release-current.json').read_text(), 'old')
            self.assertIn('build output', stdout)

    def test_install_failure_reports_published_release(self):
        with tempfile.TemporaryDirectory() as tmp:
            stderr, stdout, dest = self.run_entry(Path(tmp), fail_install=True)
            self.assertIn('安装固定候选：失败', stderr)
            self.assertNotIn('完成', stderr)
            self.assertNotEqual((dest / 'release-current.json').read_text(), 'old')

class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.dest = self.root / 'releases'; self.dest.mkdir()
        self.stage = self.root / 'stage'; self.stage.mkdir()
        for base, prefix in ((self.dest, 'old'), (self.stage, 'new')):
            (base / 'Safarier AI.app').mkdir()
            (base / 'Safarier AI.app' / 'content').write_text(prefix)
            for name in ('candidate-sha256.json', 'release-current.json'):
                (base / name).write_text(prefix + name)
    def tearDown(self): self.tmp.cleanup()
    def values(self):
        return [(self.dest / 'Safarier AI.app' / 'content').read_text()] + [(self.dest / n).read_text() for n in ('candidate-sha256.json','release-current.json')]
    def test_success_keeps_backup_and_publishes_all(self):
        backup = release.publish(self.dest, self.stage)
        self.assertEqual(self.values(), ['new','newcandidate-sha256.json','newrelease-current.json'])
        self.assertEqual((backup / 'Safarier AI.app' / 'content').read_text(), 'old')
        self.assertFalse((self.dest / '.unified-transaction').exists())
    def test_failure_rolls_back_all_paths(self):
        original = release.os.rename
        def fail(src, dst):
            if Path(src) == self.stage / 'candidate-sha256.json': raise OSError('injected')
            return original(src, dst)
        with mock.patch.object(release.os, 'rename', side_effect=fail):
            with self.assertRaisesRegex(OSError, 'injected'): release.publish(self.dest, self.stage)
        self.assertEqual(self.values(), ['old','oldcandidate-sha256.json','oldrelease-current.json'])
        self.assertFalse((self.dest / '.unified-transaction').exists())
    def test_rollback_failure_keeps_recovery_marker(self):
        original = release.os.rename
        def fail(src, dst):
            if Path(src) == self.stage / 'candidate-sha256.json' or (Path(src) == self.dest / 'Safarier AI.app' and Path(dst) == self.stage / 'Safarier AI.app'):
                raise OSError('injected')
            return original(src, dst)
        with mock.patch.object(release.os, 'rename', side_effect=fail):
            with self.assertRaisesRegex(RuntimeError, '回滚未完成'): release.publish(self.dest, self.stage)
        self.assertTrue((self.dest / '.unified-transaction' / 'RECOVERY.txt').is_file())
        with self.assertRaisesRegex(RuntimeError, '恢复'): release.publish(self.dest, self.stage)
    def test_interruption_as_marker_appears_has_recovery_material(self):
        original = release.os.rename
        def interrupt(src, dst):
            original(src, dst)
            if Path(dst) == self.dest / '.unified-transaction': raise KeyboardInterrupt()
        with mock.patch.object(release.os, 'rename', side_effect=interrupt):
            with self.assertRaises(KeyboardInterrupt): release.publish(self.dest, self.stage)
        marker = self.dest / '.unified-transaction'
        self.assertTrue((marker / 'RECOVERY.txt').is_file())
        self.assertTrue((marker / 'previous').is_dir())
        self.assertEqual(self.values(), ['old','oldcandidate-sha256.json','oldrelease-current.json'])
        with self.assertRaisesRegex(RuntimeError, '恢复'): release.publish(self.dest, self.stage)
    def test_residual_transaction_stops_before_changes(self):
        (self.dest / '.unified-transaction').mkdir()
        with self.assertRaisesRegex(RuntimeError, '恢复'): release.publish(self.dest, self.stage)
        self.assertEqual(self.values(), ['old','oldcandidate-sha256.json','oldrelease-current.json'])
    def test_lock_rejects_second_writer(self):
        with release.writer_lock(self.dest):
            with self.assertRaisesRegex(RuntimeError, '锁'):
                with release.writer_lock(self.dest): pass

class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.apps = self.root / 'Applications'; self.apps.mkdir(mode=0o700)
        self.fixed = self.root / 'fixed.app'; self.fixed.mkdir()
        (self.fixed / 'content').write_text('new')
        self.target = self.apps / 'Safarier AI.app'
        self.checker = mock.patch.object(release.package, 'check_app', side_effect=lambda app, pins: None)
        self.checker.start(); self.addCleanup(self.checker.stop)
        self.processes = mock.patch.object(release, 'running_target_processes', return_value=[] , create=True)
        self.processes.start(); self.addCleanup(self.processes.stop)

    def install(self):
        return release.install_candidate(self.fixed, {}, self.apps)

    def test_install_retains_previous_and_verifies_installed_copy(self):
        self.target.mkdir(); (self.target / 'content').write_text('old')
        backup = self.install()
        self.assertEqual((self.target / 'content').read_text(), 'new')
        self.assertEqual((backup / 'content').read_text(), 'old')
        self.assertTrue(any(c.args[0] == self.target for c in release.package.check_app.call_args_list))
        self.assertFalse((self.apps / '.safarier-install-transaction').exists())

    def test_first_install(self):
        self.assertIsNone(self.install())
        self.assertEqual((self.target / 'content').read_text(), 'new')

    def test_running_target_stops_without_replacement(self):
        self.target.mkdir(); (self.target / 'content').write_text('old')
        release.running_target_processes.return_value = ['123']
        with self.assertRaisesRegex(RuntimeError, '运行'): self.install()
        self.assertEqual((self.target / 'content').read_text(), 'old')

    def test_failure_after_replacement_restores_previous(self):
        self.target.mkdir(); (self.target / 'content').write_text('old')
        release.package.check_app.side_effect = lambda app, pins: (_ for _ in ()).throw(ValueError('invalid')) if app == self.target else None
        with self.assertRaisesRegex(ValueError, 'invalid'): self.install()
        self.assertEqual((self.target / 'content').read_text(), 'old')

    def test_first_install_failure_removes_candidate_from_target(self):
        release.package.check_app.side_effect = lambda app, pins: (_ for _ in ()).throw(ValueError('invalid')) if app == self.target else None
        with self.assertRaisesRegex(ValueError, 'invalid'): self.install()
        self.assertFalse(self.target.exists())

    def test_process_starting_during_copy_stops_before_replacement(self):
        self.target.mkdir(); (self.target / 'content').write_text('old')
        release.running_target_processes.side_effect = [[], ['123']]
        with self.assertRaisesRegex(RuntimeError, '运行'): self.install()
        self.assertEqual((self.target / 'content').read_text(), 'old')

    def test_residual_transaction_fails_closed(self):
        (self.apps / '.safarier-install-transaction').mkdir()
        with self.assertRaisesRegex(RuntimeError, '恢复'): self.install()

    def test_symlink_target_is_rejected(self):
        self.target.symlink_to(self.fixed)
        with self.assertRaisesRegex(RuntimeError, '符号链接'): self.install()

    def test_install_lock_rejects_second_writer(self):
        with release.writer_lock(self.apps):
            with self.assertRaisesRegex(RuntimeError, '锁'):
                with release.writer_lock(self.apps): pass

    def test_interrupt_after_marker_preserves_recovery(self):
        original = release.os.rename
        def interrupt(src, dst):
            original(src, dst)
            if Path(dst) == self.apps / '.safarier-install-transaction': raise KeyboardInterrupt()
        with mock.patch.object(release.os, 'rename', side_effect=interrupt):
            with self.assertRaises(KeyboardInterrupt): self.install()
        self.assertTrue((self.apps / '.safarier-install-transaction' / 'RECOVERY.txt').is_file())
        with self.assertRaisesRegex(RuntimeError, '恢复'): self.install()

    def test_rollback_failure_preserves_recovery(self):
        self.target.mkdir(); (self.target / 'content').write_text('old')
        original = release.os.rename
        def fail(src, dst):
            if Path(src) == self.target and Path(dst).name == 'candidate.app': raise OSError('rollback')
            return original(src, dst)
        release.package.check_app.side_effect = lambda app, pins: (_ for _ in ()).throw(ValueError('invalid')) if app == self.target else None
        with mock.patch.object(release.os, 'rename', side_effect=fail):
            with self.assertRaisesRegex(RuntimeError, '回滚未完成'): self.install()
        self.assertTrue((self.apps / '.safarier-install-transaction' / 'RECOVERY.txt').is_file())

    def test_directory_permissions_are_checked(self):
        self.apps.chmod(0o777)
        with self.assertRaisesRegex(RuntimeError, '权限'): self.install()
        self.assertFalse(self.target.exists())

class ProcessDetectionTests(unittest.TestCase):
    def test_real_process_inside_target_is_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / 'Safarier AI.app'
            executable = target / 'Contents/MacOS/Safarier AI Browser'
            executable.parent.mkdir(parents=True)
            shutil.copyfile('/bin/sleep', executable)
            executable.chmod(0o700)
            child = subprocess.Popen([str(executable), '30'])
            try:
                self.assertIn(str(child.pid), release.running_target_processes(target))
            finally:
                child.terminate()
                child.wait(timeout=5)

    def test_process_list_failure_stops_installation(self):
        with mock.patch.object(release.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'ps')):
            with self.assertRaises(subprocess.CalledProcessError):
                release.running_target_processes(Path('/tmp/fake.app'))

if __name__ == '__main__': unittest.main()
