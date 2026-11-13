#!/usr/bin/env python3
"""Launch only the owned background fixture; never post input or activate an app."""
import argparse, datetime, json, os, pathlib, signal, subprocess, sys, time, tempfile, shutil, re, stat, hashlib
p=argparse.ArgumentParser()
group=p.add_mutually_exclusive_group(required=True)
group.add_argument('--isolated-ui',action='store_true',help='operator confirms isolated GUI; isolation is not verified')
group.add_argument('--authorized-local-gui',action='store_true',help='explicit local GUI authorization; isolation is not claimed')
p.add_argument('--app-path');p.add_argument('--results-root');p.add_argument('--mode',default='fixed',choices=['fixed','stub']);p.add_argument('--visibility',default='background',choices=['background','occluded','hidden']);p.add_argument('--label',required=True);p.add_argument('--expect-red',action='store_true')
a=p.parse_args()
if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,100}',a.label):p.error('label must be a safe single path component')
repo=pathlib.Path(__file__).resolve().parents[2]
if a.authorized_local_gui:
 if not a.app_path or not a.results_root: p.error('--app-path and --results-root are required')
 if a.mode != 'fixed' or a.visibility != 'background' or a.expect_red: p.error('local pointer smoke requires fixed/background and no --expect-red')
 stage=repo/'.build/automation-gui-pointer-smoke-20261104'
 receipt=stage/'runtime-root-authorization.json'
 try:
  rst=os.lstat(receipt)
  if not stat.S_ISREG(rst.st_mode) or rst.st_uid != os.getuid() or rst.st_mode & 0o022: p.error('unsafe runtime root receipt')
  pin=json.loads(receipt.read_text())
  authorized=pathlib.Path(pin['path'])
  st=os.lstat(authorized)
  if (not authorized.is_absolute() or '..' in authorized.parts or not stat.S_ISDIR(st.st_mode) or
      st.st_uid != os.getuid() or st.st_uid != pin['uid'] or st.st_dev != pin['device'] or
      st.st_ino != pin['inode'] or stat.S_IMODE(st.st_mode) != 0o700 or pin['mode'] != '0700'):
   p.error('runtime root does not match authorization receipt')
 except (OSError,ValueError,KeyError,TypeError) as exc: p.error('runtime root receipt invalid: '+str(exc))
 app=pathlib.Path(a.app_path); root=pathlib.Path(a.results_root)
 if root != authorized or app.parent != authorized: p.error('app and results must use the exact pinned root')
 def check_path(path, directory, private=False):
  if not path.is_absolute() or '..' in path.parts: p.error('absolute normalized path required')
  try:
   relative=path.relative_to(authorized)
   for parent in [*reversed(authorized.parents),authorized]:
    if stat.S_ISLNK(os.lstat(parent).st_mode): p.error('symlink in authorized root path')
   for part in [authorized, *(authorized.joinpath(*relative.parts[:i]) for i in range(1,len(relative.parts)+1))]:
    st=os.lstat(part)
    if stat.S_ISLNK(st.st_mode) or st.st_uid != os.getuid(): p.error('symlink or foreign owner: '+str(part))
    if part != path or directory:
     if not stat.S_ISDIR(st.st_mode) or st.st_mode & 0o022: p.error('unsafe directory: '+str(part))
    elif not stat.S_ISREG(st.st_mode) or st.st_mode & 0o022: p.error('unsafe file: '+str(part))
   if private and os.lstat(path).st_mode & 0o077: p.error('directory is not private: '+str(path))
  except (OSError, ValueError) as exc: p.error('unsafe authorized path: '+str(exc))
 check_path(authorized, True, True); check_path(root, True, True); check_path(app, True)
 if app.name != 'BackgroundInputProbe.app': p.error('unexpected app name')
 exe=app/'Contents/MacOS/BackgroundInputProbe'; fixture=app/'Contents/Resources/fixture.html'
 check_path(exe, False); check_path(fixture, False)
 if not os.access(exe,os.X_OK): p.error('app executable is not executable')
 out=root/a.label
 try:
  os.mkdir(out,0o700)
  for child in ('runtime','tmp'): os.mkdir(out/child,0o700)
 except OSError as exc: p.error('exclusive result creation failed: '+str(exc))
 runtime=out/'runtime'
 cmd=[str(exe),'--output',str(runtime),'--mode','fixed','--visibility','background','--scenario','pointer-smoke']
 env=os.environ.copy()
 env.update(TMPDIR=str(out/'tmp'))
 metadata={'command':cmd,'operatorConfirmedIsolation':False,'isolationVerified':False,'userAuthorizedLocalGUI':True,'diagnosticOnly':True,'formalAcceptance':False,'shippingAdmission':False,'executableSHA256':hashlib.sha256(exe.read_bytes()).hexdigest(),'fixtureSHA256':hashlib.sha256(fixture.read_bytes()).hexdigest(),'environmentOverrides':{'TMPDIR':env['TMPDIR']},'environment':env,'runtimeRootDevice':st.st_dev,'runtimeRootInode':st.st_ino}
 sources=[]
 for directory in ('Sources/Safarier','Sources/SafarierCore','Sources/SafarierNetwork','Sources/SafarierWebKit'):
  sources.extend(sorted((repo/directory).rglob('*.swift')))
 sources.extend(repo/x for x in ('Sources/SafarierObjCSupport/SFRRuntime.m','Sources/SafarierObjCSupport/include/SafarierObjCSupport.h','scripts/background-input-probe/NativeEvents.swift','scripts/background-input-probe/ProbeMain.swift','scripts/background-input-probe/fixture.html','scripts/background-input-probe/build-native.sh','scripts/background-input-probe/build-probe.sh','scripts/background-input-probe/run.py'))
 metadata['sourceSHA256']={str(path.relative_to(repo)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
 (out/'launch.json').write_text(json.dumps(metadata,indent=2))
 try:
  with (out/'stdout.log').open('x') as stdout, (out/'stderr.log').open('x') as stderr:
   process=subprocess.Popen(cmd,stdin=subprocess.DEVNULL,stdout=stdout,stderr=stderr,env=env,cwd=str(runtime))
   try: process.communicate(timeout=70)
   except subprocess.TimeoutExpired:
    (out/'outcome.json').write_text(json.dumps({'ownPID':process.pid,'status':'cleanup_unconfirmed','timeout':True},indent=2))
    print('FAIL: own process timeout; cleanup_unconfirmed',out);sys.exit(2)
 except OSError as exc:
  (out/'outcome.json').write_text(json.dumps({'status':'launch_failed','error':str(exc)},indent=2));sys.exit(2)
 report=runtime/'report.json'
 try:
  st=os.lstat(report)
  if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o022: raise ValueError('unsafe report')
  data=json.loads(report.read_text())
  cases=data.get('cases',[])
  required={'ready_background','hover','hover_exit','held','drag','release','trusted_pointer','page_activity_restored','no_global_input_or_activation'}
  observed={case.get('name') for case in cases if isinstance(case,dict) and case.get('passed') is True}
  ok=(process.returncode==0 and data.get('allPassed') is True and data.get('scenario')=='pointer-smoke' and required.issubset(observed))
 except (OSError,ValueError): ok=False
 (out/'outcome.json').write_text(json.dumps({'ownPID':process.pid,'exitCode':process.returncode,'allPassed':ok,'status':'completed' if ok else 'failed'},indent=2))
 print('RESULT',out,'PASS' if ok else 'FAIL');sys.exit(0 if ok else 1)
if a.app_path or a.results_root: p.error('--app-path and --results-root require --authorized-local-gui')
root=repo/'.build/mcc-safarier-probe'
parents=[repo/'.build',root,root/'runs']
for parent in parents:
 if parent.is_symlink() or (parent.exists() and not parent.is_dir()):p.error(f'unsafe output parent: {parent}')
for parent in parents:parent.mkdir(mode=0o700,exist_ok=True)
out=root/'runs'/a.label
out.mkdir(mode=0o700,exist_ok=False)
runtime=pathlib.Path(tempfile.mkdtemp(prefix='safarier-native-probe-',dir='/tmp'))
os.chmod(runtime,0o700)
app=root/'BackgroundInputProbe.app'
cmd=['/usr/bin/open','-g','-n','-W',str(app),'--args','--output',str(runtime),'--mode',a.mode,'--visibility',a.visibility]
(out/'launch.json').write_text(json.dumps({'command':cmd,'started':datetime.datetime.now().astimezone().isoformat(),'diagnosticOnly':True,'operatorConfirmedIsolation':True,'isolationVerified':False,'formalAcceptance':False,'shippingAdmission':False,'warning':'Legacy diagnostic fixture uses LaunchServices and legacy PID cleanup; isolation is not verified. Not formal G1/G3 or G2/G5 acceptance and not a Safarier recipient.'},indent=2))
try:
 r=subprocess.run(cmd,capture_output=True,text=True,errors='replace',timeout=70)
 (out/'launcher.log').write_text(r.stdout+r.stderr)
except subprocess.TimeoutExpired:
 pidfile=runtime/'pid'
 if pidfile.exists():
  pid=int(pidfile.read_text())
  try: exe=subprocess.check_output(['ps','-p',str(pid),'-o','command='],text=True,errors='replace').strip()
  except subprocess.CalledProcessError: exe=''
  if exe.startswith(str(app/'Contents/MacOS/BackgroundInputProbe')+' ') and str(runtime) in exe:
   try: os.kill(pid,signal.SIGTERM)
   except ProcessLookupError: pass
 # A process can stall before writing its pid. Match only this unique owned output path.
 for line in subprocess.check_output(['ps','-axo','pid=,command='],text=True,errors='replace').splitlines():
  parts=line.strip().split(None,1)
  if len(parts)==2 and parts[1].startswith(str(app/'Contents/MacOS/BackgroundInputProbe')+' ') and str(runtime) in parts[1]:
   try: os.kill(int(parts[0]),signal.SIGTERM)
   except ProcessLookupError: pass
 (out/'launcher.log').write_text('owned fixture exceeded 70s launch/execution deadline; only matching own process terminated\n')
 shutil.copytree(runtime,out,dirs_exist_ok=True);shutil.rmtree(runtime)
 print('FAIL: owned fixture launch timed out',out);sys.exit(2)
shutil.copytree(runtime,out,dirs_exist_ok=True);shutil.rmtree(runtime)
report=out/'report.json'
if not report.exists():
 print('FAIL: fixture exited without report',out);sys.exit(2)
s=json.loads(report.read_text())
s.update({'diagnosticOnly':True,'operatorConfirmedIsolation':True,'isolationVerified':False,'formalAcceptance':False,'shippingAdmission':False,'warning':'Legacy diagnostic fixture uses LaunchServices and legacy PID cleanup; isolation is not verified. Not formal G1/G3 or G2/G5 acceptance and not a Safarier recipient.'})
report.write_text(json.dumps(s,indent=2,ensure_ascii=False))
print('REPORT',report)
for c in s.get('cases',[]): print(('PASS' if c['passed'] else 'FAIL'),c['name'])
print('summary',json.dumps({k:s.get(k) for k in ('mode','visibility','allPassed','error')},ensure_ascii=False))
if a.expect_red:
 ready=next((c for c in s['cases'] if c['name']=='ready_background'),{})
 click=next((c for c in s['cases'] if c['name']=='click'),{})
 assert ready.get('passed') is True and click.get('passed') is False and not s['allPassed'], 'Red baseline did not fail for the expected browser effect'
 print('EXPECTED_RED_CONFIRMED');sys.exit(0)
sys.exit(0 if s['allPassed'] else 1)
