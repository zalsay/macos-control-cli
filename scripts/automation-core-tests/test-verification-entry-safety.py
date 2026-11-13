import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class EntrySafety(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='stage13-mirror-')
        self.root = Path(self.tmp.name)
        self.probe = self.root/'scripts/background-input-probe'
        self.probe.mkdir(parents=True)
        for name in ('matrix.py', 'run.py'):
            shutil.copy(ROOT/'scripts/background-input-probe'/name, self.probe/name)
        shutil.copy(ROOT/'scripts/verify-background-input.sh', self.root/'scripts/verify-background-input.sh')
        self.bin = self.root/'bin'; self.bin.mkdir()
        self.marker = self.root/'commands'
        self.platform = self.root/'Xcode with spaces/MacOSX.platform'
        (self.platform/'Developer/Library/Frameworks').mkdir(parents=True)
        (self.platform/'Developer/usr/lib').mkdir(parents=True)
        stub = '#!/bin/sh\necho "$(basename "$0") $*" >> "$MARKER"\nif [ "$(basename "$0")" = xcrun ]; then printf "%s|%s\n" "${SWIFT_EXEC_MANIFEST-unset}" "${SWIFTPM_MODULECACHE_OVERRIDE-unset}" >> "$MARKER_ENV"; fi\nif [ "${STUB_BINARY:-}" = "$(basename "$0")" ]; then printf "\\377"; printf "\\376" >&2; fi\nif [ "${STUB_FAIL:-}" = "$(basename "$0")" ]; then exit 1; fi\nexit 0\n'
        for path in (self.root/'scripts/test-native-background-input.sh', self.probe/'build-native.sh', self.probe/'build-probe.sh', *(self.bin/x for x in ('xcode-select','xcrun','swift'))):
            path.write_text(stub); path.chmod(0o755)
        # Intercept the absolute /usr/bin/open even in the old script.
        (self.root/'sitecustomize.py').write_text('''import subprocess, os\n_original = subprocess.run\ndef safe_run(args, *a, **kw):\n if isinstance(args, (tuple,list)) and args and os.environ.get("STUB_RAISE") == os.path.basename(args[0]):
  raise subprocess.CalledProcessError(42, args)
 if isinstance(args, (tuple,list)) and args and os.environ.get("STUB_TIMEOUT") == args[0]:
  raise subprocess.TimeoutExpired(args, kw.get("timeout", 0), output=b"timeout")
 if isinstance(args, (tuple,list)) and args and args[0] == "/usr/bin/open":\n  with open(os.environ["MARKER"], "a") as f: f.write("OPEN\\n")\n  if os.environ.get("PRODUCE_REPORT"):
   import json, pathlib
   out = pathlib.Path(args[args.index("--output")+1])
   (out/"report.json").write_text(json.dumps({"allPassed":True,"cases":[]}))
  return subprocess.CompletedProcess(args, 0, "", "")\n if isinstance(args, (tuple,list)) and args and args[0] == "xcrun":
  import json
  with open(os.environ["ARGV_MARKER"], "a") as f: f.write(json.dumps(args) + "\\n")
  if "--show-sdk-platform-path" in args:
   r = _original(args, *a, **kw)
   return subprocess.CompletedProcess(args, int(os.environ.get("PLATFORM_EXIT", r.returncode)), os.environ.get("PLATFORM_OUTPUT", os.environ["PLATFORM_PATH"] + "\\n"), r.stderr)
  if "-typecheck" in args:
   if os.environ.get("TYPECHECK_TIMEOUT"):
    raise subprocess.TimeoutExpired(args, kw.get("timeout", 0), output=b"typecheck timeout", stderr=b"timeout stderr")
   if os.environ.get("TYPECHECK_FAIL"):
    return subprocess.CompletedProcess(args, 1, "", "typecheck failed")
 return _original(args, *a, **kw)\nsubprocess.run = safe_run\n''')
        self.env = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ['PATH'], PYTHONPATH=str(self.root), MARKER=str(self.marker), MARKER_ENV=str(self.root/'env-marker'), ARGV_MARKER=str(self.root/'argv-marker'), PLATFORM_PATH=str(self.platform))
    def tearDown(self): self.tmp.cleanup()
    def call(self, entry, *args):
        cmd = ['bash', str(self.root/'scripts/verify-background-input.sh')] if entry == 'verify' else ['python3', str(self.probe/(entry+'.py'))]
        return subprocess.run(cmd+list(args), env=self.env, capture_output=True, text=True, timeout=10)
    def commands(self): return self.marker.read_text().splitlines() if self.marker.exists() else []
    def test_noargs_and_help_are_safe(self):
        for entry,args in [('verify',()),('verify',('--help',)),('matrix',()),('matrix',('--help',)),('run',('--help',)),('run',('--label','safe'))]:
            with self.subTest(entry=entry,args=args):
                self.marker.unlink(missing_ok=True)
                r=self.call(entry,*args)
                self.assertEqual(self.commands(), [])
                self.assertEqual(r.returncode == 0, '--help' in args)
    def test_invalid_arguments_are_safe(self):
        for entry,args in [('verify',('--nonsense',)),('matrix',('--isolated-ui','--preflight')),('matrix',('--isolated-ui','--prefix','../x')),('matrix',('--isolated-ui','--states','hidden,hidden')),('matrix',('--isolated-ui','--rounds','0')),('run',('--isolated-ui','--label','../x')),('run',('--isolated-ui','--label','ok','--mode','bad')),('run',('--isolated-ui','--label','ok','--visibility','bad'))]:
            with self.subTest(entry=entry,args=args):
                self.marker.unlink(missing_ok=True)
                self.assertNotEqual(self.call(entry,*args).returncode,0)
                self.assertEqual(self.commands(),[])
                self.assertFalse((self.root/'.build').exists())
    def test_xctest_typecheck_uses_resolved_platform_paths(self):
        self.env['SDKROOT']=str(self.root/'untrusted-sdk')
        r=self.call('matrix','--preflight','--prefix','platform-success')
        self.assertEqual(r.returncode,0,r.stderr)
        calls=[json.loads(line) for line in (self.root/'argv-marker').read_text().splitlines()]
        cmd=next(c for c in calls if '-typecheck' in c)
        self.assertEqual(cmd[:4],['xcrun','--sdk','macosx','swiftc'])
        self.assertIn('-F',cmd)
        self.assertIn('-I',cmd)
        self.assertIn(['xcrun','--sdk','macosx','--show-sdk-platform-path'],calls)
        self.assertEqual(cmd[cmd.index('-F')+1],str(self.platform/'Developer/Library/Frameworks'))
        self.assertEqual(cmd[cmd.index('-I')+1],str(self.platform/'Developer/usr/lib'))

    def test_platform_lookup_rejects_failure_and_invalid_output(self):
        for index,(output,exit_code) in enumerate([('',0), ('relative/MacOSX.platform\n',0), (str(self.platform)+'\nextra\n',0), (str(self.root/'Other.platform')+'\n',0), (str(self.root/'missing/MacOSX.platform')+'\n',0), (str(self.platform)+'\n',1), (str(self.platform)+'/../MacOSX.platform\n',0)]):
            with self.subTest(output=output,exit_code=exit_code):
                self.env.update(PLATFORM_OUTPUT=output,PLATFORM_EXIT=str(exit_code))
                prefix='invalid'+str(index)
                r=self.call('matrix','--preflight','--prefix',prefix)
                self.assertNotEqual(r.returncode,0)
                summary=json.loads((self.root/'.build/mcc-safarier-probe'/prefix/'summary.json').read_text())
                self.assertEqual(summary['g0Status'],'blocked'); self.assertEqual(summary['xctestStatus'],'blocked')
                self.assertTrue(summary['commands']['xctestTypecheck']['skipped'])
                self.assertIn('platform',summary['commands']['xctestTypecheck']['stderr'])
                self.assertEqual(summary['commands']['macosPlatform']['command'],['xcrun','--sdk','macosx','--show-sdk-platform-path'])
                for key in ('formalAcceptance','shippingAdmission','fullSwiftTestRun','GUIExecuted'): self.assertIs(summary[key],False)
        calls=[json.loads(line) for line in (self.root/'argv-marker').read_text().splitlines()]
        self.assertFalse(any('-typecheck' in c for c in calls))

    def test_platform_lookup_timeout_skips_typecheck(self):
        self.env['STUB_TIMEOUT']='xcrun'
        r=self.call('matrix','--preflight','--prefix','platform-timeout')
        self.assertNotEqual(r.returncode,0)
        summary=json.loads((self.root/'.build/mcc-safarier-probe/platform-timeout/summary.json').read_text())
        self.assertTrue(summary['commands']['macosPlatform']['timedOut'])
        self.assertEqual(summary['commands']['macosPlatform']['stdout'],'timeout')
        self.assertTrue(summary['commands']['xctestTypecheck']['skipped'])
        self.assertEqual(summary['g0Status'],'blocked')

    def test_platform_missing_required_directories(self):
        for index,relative in enumerate(('Developer/Library/Frameworks','Developer/usr/lib')):
            with self.subTest(directory=relative):
                directory=self.platform/relative; directory.rmdir()
                prefix='missing'+str(index)
                r=self.call('matrix','--preflight','--prefix',prefix)
                self.assertNotEqual(r.returncode,0)
                summary=json.loads((self.root/'.build/mcc-safarier-probe'/prefix/'summary.json').read_text())
                self.assertEqual(summary['g0Status'],'blocked')
                self.assertIn('does not exist',summary['commands']['xctestTypecheck']['stderr'])
                self.assertTrue(summary['commands']['xctestTypecheck']['skipped'])
                directory.mkdir()

    def test_xctest_failure_and_timeout_block(self):
        for variable in ('TYPECHECK_FAIL','TYPECHECK_TIMEOUT'):
            with self.subTest(variable=variable):
                self.env[variable]='1'
                r=self.call('matrix','--preflight','--prefix',variable)
                self.env.pop(variable)
                self.assertNotEqual(r.returncode,0)
                summary=json.loads((self.root/'.build/mcc-safarier-probe'/variable/'summary.json').read_text())
                self.assertEqual(summary['g0Status'],'blocked'); self.assertEqual(summary['xctestStatus'],'blocked')
                result=summary['commands']['xctestTypecheck']
                self.assertEqual(result['timedOut'],variable=='TYPECHECK_TIMEOUT')
                self.assertIn('timeout' if result['timedOut'] else 'failed',result['stderr'])

    def test_preflight_allowlist_and_summary(self):
        r=self.call('matrix','--preflight','--prefix','g0')
        self.assertEqual(r.returncode,0,r.stderr)
        commands=self.commands()
        self.assertEqual([c.split()[0] for c in commands], ['xcode-select','xcrun','xcrun','xcrun','xcrun','xcrun','xcrun'])
        self.assertIn('dump-package',commands[4]); self.assertIn('--scratch-path',commands[4]); self.assertIn('--cache-path',commands[4])
        self.assertIn('swift --version',commands[3]); self.assertIn('--manifest-cache none',commands[4]); self.assertIn('--disable-dependency-cache',commands[4]); self.assertIn('--sdk macosx --show-sdk-platform-path',commands[5]); self.assertIn('--sdk macosx swiftc -typecheck',commands[6]); self.assertIn('-module-cache-path',commands[6])
        self.assertEqual((self.root/'.build/mcc-safarier-probe/g0').stat().st_mode & 0o777,0o700)
        summary=json.loads((self.root/'.build/mcc-safarier-probe/g0/summary.json').read_text())
        self.assertEqual(summary['g0Status'],'unverified')
        self.assertTrue(summary['sandboxedHome']); self.assertTrue(summary['probeManifestOverrideCleared']); self.assertIn('deleted',summary['temporaryPathsNote'])
        self.assertEqual(summary['defaultManifestStatus'],'passed')
        self.assertEqual(summary['xctestStatus'],'passed')
        for key in ('formalAcceptance','shippingAdmission','fullSwiftTestRun','GUIExecuted'): self.assertIs(summary[key],False)
        self.assertEqual(len(summary['commands']),7)
        for item in summary['commands'].values(): self.assertIn('durationSeconds',item); self.assertIn('stdout',item); self.assertIn('exitCode',item)
        self.marker.unlink(); self.assertNotEqual(self.call('matrix','--preflight','--prefix','g0').returncode,0); self.assertEqual(self.commands(),[])
    def test_preflight_failure_timeout_and_override_block(self):
        for variable,value,prefix in [('STUB_FAIL','xcrun','fail'),('STUB_TIMEOUT','xcrun','timeout'),('SWIFT_EXEC_MANIFEST','overlay','overlay')]:
            with self.subTest(variable=variable):
                self.env[variable]=value
                r=self.call('matrix','--preflight','--prefix',prefix)
                self.env.pop(variable)
                self.assertNotEqual(r.returncode,0)
                summary=json.loads((self.root/'.build/mcc-safarier-probe'/prefix/'summary.json').read_text())
                self.assertEqual(summary['g0Status'],'blocked')
                if prefix=='overlay':
                    self.assertTrue(summary['overrideDetected']); self.assertEqual(summary['defaultManifestStatus'],'blocked'); self.assertTrue(summary['probeManifestOverrideCleared'])
                    for line in (self.root/'env-marker').read_text().splitlines():
                        override,cache=line.split('|'); self.assertEqual(override,'unset'); self.assertNotEqual(cache,'unset'); self.assertIn('/.build/mcc-safarier-probe/',cache)
                if prefix=='timeout': self.assertTrue(summary['commands']['swiftCompiler']['timedOut'])
    def test_empty_manifest_override_is_blocked_and_cleared(self):
        self.env['SWIFT_EXEC_MANIFEST']=''
        r=self.call('matrix','--preflight','--prefix','empty')
        self.assertNotEqual(r.returncode,0)
        summary=json.loads((self.root/'.build/mcc-safarier-probe/empty/summary.json').read_text())
        self.assertTrue(summary['overrideDetected']); self.assertTrue(summary['probeManifestOverrideCleared'])
        self.assertEqual(summary['g0Status'],'blocked'); self.assertEqual(summary['defaultManifestStatus'],'blocked')
        self.assertTrue(all(line.split('|')[0]=='unset' for line in (self.root/'env-marker').read_text().splitlines()))
    def test_preflight_invalid_output_encoding_is_recorded(self):
        self.env['STUB_BINARY']='xcrun'
        r=self.call('matrix','--preflight','--prefix','binary')
        self.assertEqual(r.returncode,0,r.stderr)
        summary=json.loads((self.root/'.build/mcc-safarier-probe/binary/summary.json').read_text())
        self.assertIn('\ufffd',summary['commands']['swiftCompiler']['stdout'])
        self.assertIn('\ufffd',summary['commands']['swiftCompiler']['stderr'])
    def test_ui_forwarding_and_report_are_diagnostic(self):
        # Replace only the mirrored run entry: it is a non-GUI forwarding stub.
        (self.probe/'run.py').write_text("""import json, os, pathlib, sys
with open(os.environ['MARKER'],'a') as f: f.write('RUN '+ ' '.join(sys.argv[1:])+'\\n')
label=sys.argv[sys.argv.index('--label')+1]
p=pathlib.Path(__file__).resolve().parents[2]/'.build/mcc-safarier-probe/runs'/label
p.mkdir(parents=True)
(p/'report.json').write_text(json.dumps({'allPassed':True,'cases':[]}))
""")
        r=self.call('verify','--isolated-ui','--prefix','ui','--states','hidden','--rounds','1')
        self.assertEqual(r.returncode,0,r.stderr)
        commands=self.commands(); self.assertEqual(len(commands),4); self.assertIn('--isolated-ui',commands[-1])
        summary=json.loads((self.root/'.build/mcc-safarier-probe/ui-matrix.json').read_text())
        for k,v in [('diagnosticOnly',True),('operatorConfirmedIsolation',True),('isolationVerified',False),('formalAcceptance',False),('shippingAdmission',False)]: self.assertIs(summary[k],v)
        self.marker.unlink(); self.assertNotEqual(self.call('matrix','--isolated-ui','--prefix','ui','--states','hidden','--rounds','1').returncode,0); self.assertEqual(self.commands(),[])
    def test_direct_run_report_and_existing_label(self):
        self.env['PRODUCE_REPORT']='1'
        r=self.call('run','--isolated-ui','--label','direct')
        self.assertEqual(r.returncode,0,r.stderr)
        s=json.loads((self.root/'.build/mcc-safarier-probe/runs/direct/report.json').read_text())
        self.assertEqual((self.root/'.build/mcc-safarier-probe/runs/direct').stat().st_mode & 0o777,0o700)
        for k,v in [('diagnosticOnly',True),('operatorConfirmedIsolation',True),('isolationVerified',False),('formalAcceptance',False),('shippingAdmission',False)]: self.assertIs(s[k],v)
        self.marker.unlink(); self.assertNotEqual(self.call('run','--isolated-ui','--label','direct').returncode,0); self.assertEqual(self.commands(),[])
    def test_parent_symlink_and_nondirectory_are_rejected(self):
        for component in ('.build','.build/mcc-safarier-probe','.build/mcc-safarier-probe/runs'):
            for kind in ('symlink','file'):
                for entry,args in [('matrix',('--preflight','--prefix','case')),('matrix',('--isolated-ui','--prefix','case')),('run',('--isolated-ui','--label','case'))]:
                    with self.subTest(component=component,kind=kind,entry=entry,args=args):
                        build=self.root/'.build'
                        if build.is_symlink() or build.is_file(): build.unlink()
                        elif build.exists(): shutil.rmtree(build)
                        outside=self.root/'outside'; outside.mkdir(exist_ok=True)
                        sentinel=outside/'keep'; sentinel.write_text('untouched')
                        parent=self.root/component; parent.parent.mkdir(parents=True,exist_ok=True)
                        if kind=='symlink': parent.symlink_to(outside, target_is_directory=True)
                        else: parent.write_text('untouched')
                        self.marker.unlink(missing_ok=True)
                        r=self.call(entry,*args)
                        self.assertNotEqual(r.returncode,0,r.stdout)
                        self.assertEqual(self.commands(),[])
                        self.assertEqual(sentinel.read_text(),'untouched')
                        self.assertEqual(sorted(x.name for x in outside.iterdir()),['keep'])
                        if kind=='file': self.assertEqual(parent.read_text(),'untouched')
    def test_build_calledprocesserror_is_reported(self):
        self.env['STUB_RAISE']='build-native.sh'
        r=self.call('matrix','--isolated-ui','--prefix','raised','--states','hidden','--rounds','1')
        self.assertNotEqual(r.returncode,0)
        s=json.loads((self.root/'.build/mcc-safarier-probe/raised-matrix.json').read_text())
        self.assertIn('build-native.sh',s['error']); self.assertIn('42',s['error'])
        self.assertIn('build-native.sh',str(s['failedCommand']))
        self.assertNotIn('Traceback',r.stderr)
if __name__ == '__main__': unittest.main()
