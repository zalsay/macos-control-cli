import importlib.util
import plistlib
import tempfile
import shutil
import sys
from unittest import mock
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('candidate_build', Path(__file__).resolve().parents[1] / 'build.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)

class TestingVariant(unittest.TestCase):
    def test_automation_usage_describes_control_of_other_apps(self):
        self.assertEqual(build.AUTHORIZATION_USAGE, 'Safarier AI 需要自动化权限，以便按照你的指令控制其他应用。')

    def test_testing_has_two_exact_icon_paths(self):
        main, runner = build.namespaces_for_variant('testing')
        icon = 'Contents/Resources/AppIcon.icns'
        self.assertEqual(runner, {build.testing_path(p) for p in build.RUNNER_NAMESPACE} | {icon})
        self.assertEqual(main, {build.testing_path(p) for p in build.MAIN_NAMESPACE}
                            | {icon, build.variant_layout('testing')['runner_rel'] + '/' + icon, build.MIHOMO_REL})
        self.assertEqual(build.namespaces_for_variant('legacy'), (build.MAIN_NAMESPACE, build.RUNNER_NAMESPACE))

    def test_variant_layout_is_exact_and_legacy_observer_unchanged(self):
        testing = build.variant_layout('testing')
        self.assertEqual(testing['app'], 'Safarier AI.app')
        self.assertEqual(testing['main_exec'], 'Contents/MacOS/Safarier AI')
        self.assertEqual(testing['runner_exec'], 'Contents/Helpers/Safarier AI Browser.app/Contents/MacOS/Safarier AI Browser')
        self.assertEqual(build.variant_layout('legacy'), build.variant_layout('observer'))
        self.assertEqual(build.artifact_paths_for_variant('legacy'), build.ARTIFACT_PATHS)
        pins = build.artifact_paths_for_variant('testing')
        self.assertEqual(len(pins), 12)
        self.assertIn(build.MIHOMO_REL, pins)
        self.assertNotIn(build.MIHOMO_REL, build.artifact_paths_for_variant('legacy'))
        self.assertIn(testing['main_exec'], pins)
        self.assertIn(testing['runner_exec'], pins)
        self.assertNotIn('Contents/MacOS/Safarier', pins)
        for variant in ('legacy', 'testing'):
            with tempfile.TemporaryDirectory() as tmp:
                app = Path(tmp)
                namespace, _ = build.namespaces_for_variant(variant)
                for name in sorted(namespace, key=lambda n: (n.count('/'), n)):
                    p = app/name
                    if any(other.startswith(name + '/') for other in namespace): p.mkdir()
                    else: p.write_bytes(b'fixture')
                build.validate_namespace(app, variant)
                with self.assertRaises((RuntimeError, OSError)):
                    build.validate_namespace(app, 'legacy' if variant == 'testing' else 'testing')

    def test_icon_design_and_generated_resource_are_both_pinned(self):
        build.validate_icon_source()
        real_sha = build.sha
        for changed in (build.ICON_SOURCE, build.ICON):
            with self.subTest(changed=changed.name), mock.patch.object(
                build, 'sha', side_effect=lambda path: '0' * 64 if path == changed else real_sha(path)
            ):
                with self.assertRaises(RuntimeError):
                    build.validate_icon_source()

    def test_runtime_both_icon_pins_match_packager(self):
        source = (build.ROOT / 'Sources/SafarierCore/BundleResourcePin.swift').read_text()
        self.assertEqual(source.count('"' + build.ICON_SHA256 + '"'), 2)

    def test_runtime_mihomo_pin_matches_packager(self):
        # The Swift candidate contract and the packager must name the same reviewed mihomo bytes.
        source = (build.ROOT / 'Sources/SafarierCore/BundleResourcePin.swift').read_text()
        self.assertIn('("' + build.MIHOMO_REL + '",false,"' + build.EXPECTED['mihomo'] + '")', source)

    def test_testing_resources_reject_missing_and_changed_icons(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp)
            main = app / 'Contents/Resources'
            runner = app / build.variant_layout('testing')['runner_rel'] / 'Contents/Resources'
            main.mkdir(parents=True); runner.mkdir(parents=True)
            shutil.copyfile(build.SDEF, main/'Safarier.sdef')
            shutil.copyfile(build.FIXTURE, main/'control-fixture.html')
            shutil.copyfile(build.FIXTURE, runner/'control-fixture.html')
            shutil.copyfile(build.ICON, main/'AppIcon.icns')
            shutil.copyfile(build.ICON, runner/'AppIcon.icns')
            mihomo = app/build.MIHOMO_REL
            mihomo.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(build.MIHOMO_SOURCE, mihomo)
            build.validate_resources(app, 'testing')
            (runner/'AppIcon.icns').unlink()
            with self.assertRaises((RuntimeError, OSError)): build.validate_resources(app, 'testing')
            (runner/'AppIcon.icns').write_bytes(b'wrong')
            with self.assertRaises(RuntimeError): build.validate_resources(app, 'testing')

    def test_testing_metadata_is_distinct_and_cannot_accept_legacy(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp)
            (app / 'Contents/Helpers/Safarier AI Browser.app/Contents').mkdir(parents=True)
            main = {'CFBundleIdentifier':'sh.safarier.testing','CFBundleExecutable':'Safarier AI','CFBundlePackageType':'APPL','LSUIElement':True,'NSAppleScriptEnabled':True,'OSAScriptingDefinition':'Safarier.sdef','CFBundleDisplayName':'Safarier AI','CFBundleName':'Safarier AI','CFBundleIconFile':'AppIcon'}
            runner = {'CFBundleIdentifier':'sh.safarier.testing.runner','CFBundleExecutable':'Safarier AI Browser','CFBundleName':'Safarier AI Browser','CFBundleDisplayName':'Safarier AI Browser','CFBundlePackageType':'APPL','LSUIElement':True,'NSAppleScriptEnabled':False,'CFBundleIconFile':'AppIcon'}
            mainfile=app/'Contents/Info.plist'; runnerfile=app/build.variant_layout('testing')['runner_rel']/'Contents/Info.plist'
            main['NSAppleEventsUsageDescription'] = build.AUTHORIZATION_USAGE
            mainfile.write_bytes(plistlib.dumps(main));runnerfile.write_bytes(plistlib.dumps(runner))
            build.validate_metadata(app, 'testing')
            for purpose in (None, '', 'unreviewed purpose'):
                changed = dict(main)
                if purpose is None: changed.pop('NSAppleEventsUsageDescription')
                else: changed['NSAppleEventsUsageDescription'] = purpose
                mainfile.write_bytes(plistlib.dumps(changed))
                with self.assertRaises(RuntimeError): build.validate_metadata(app, 'testing')
            mainfile.write_bytes(plistlib.dumps(main))
            self.assertNotIn('NSAppleEventsUsageDescription', runner)
            for info, file, old in ((main, mainfile, 'Safarier'), (runner, runnerfile, 'SafarierRunner')):
                for key in ('CFBundleName', 'CFBundleDisplayName', 'CFBundleExecutable'):
                    saved = info[key]; info[key] = old; file.write_bytes(plistlib.dumps(info))
                    with self.assertRaises(RuntimeError): build.validate_metadata(app, 'testing')
                    info[key] = saved; file.write_bytes(plistlib.dumps(info))
            main['CFBundleIdentifier']='sh.safarier.boundcandidate'; mainfile.write_bytes(plistlib.dumps(main))
            with self.assertRaises(RuntimeError): build.validate_metadata(app, 'testing')

class TestingConsentMode(unittest.TestCase):
    def test_testing_input_reaches_receipt_but_disallows_consent(self):
        sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
        try:
            import run as harness
            common = dict(host='unused', app='unused', expected='x', runner_expected='x', label='x',
                          runtime_root_receipt=str(harness.TEST_APP_STAGE.parent/'receipt.json'),
                          scenario='testing-input', variant='testing')
            with mock.patch.object(harness, 'read_root_receipt', side_effect=LookupError('reached')):
                with self.assertRaisesRegex(LookupError, 'reached'):
                    harness.run_host(preflight_only=False, request_consent_once=False, **common)
                with self.assertRaises(RuntimeError):
                    harness.run_host(preflight_only=True, request_consent_once=True, **common)
        finally:
            sys.path.pop(0)

    def test_consent_requires_testing_preflight_and_reaches_receipt_gate(self):
        sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
        try:
            import run as harness
            common = dict(host='unused', app='unused', expected='x', runner_expected='x', label='x',
                          runtime_root_receipt=str(harness.TEST_APP_STAGE.parent/'receipt.json'),
                          scenario='testing', variant='testing')
            with mock.patch.object(harness, 'read_root_receipt', side_effect=LookupError('reached')):
                with self.assertRaisesRegex(LookupError, 'reached'):
                    harness.run_host(preflight_only=True, request_consent_once=True, **common)
                with self.assertRaises(RuntimeError):
                    harness.run_host(preflight_only=False, request_consent_once=True, **common)
        finally:
            sys.path.pop(0)

if __name__ == '__main__': unittest.main()
