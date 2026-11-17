#![cfg(unix)]
use copis_chrome::{native::Helper, service::Native};
use serde_json::json;
use std::{
    os::unix::fs::PermissionsExt,
    time::{Duration, Instant},
};
struct File(std::path::PathBuf);
impl Drop for File {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}
#[test]
fn script_remaining_deadline_bounds_blocked_native_request() {
    let file = File(std::env::temp_dir().join(format!(
        "mcc-script-native-{}.py",
        copis_chrome::protocol::random_id().unwrap()
    )));
    std::fs::write(&file.0,"#!/usr/bin/env python3\nimport sys,json,time\nfor line in sys.stdin:\n r=json.loads(line)\n if r['action']=='type': time.sleep(1)\n print(json.dumps({'id':r['id'],'ok':True,'data':{'sent':True}}),flush=True)\n").unwrap();
    std::fs::set_permissions(&file.0, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut helper = Helper::with_timeout(&file.0, Duration::from_secs(10)).unwrap();
    helper.request(json!({"action":"permissions"})).unwrap();
    helper.set_request_deadline(Some(Instant::now() + Duration::from_millis(60)));
    let start = Instant::now();
    let error = helper
        .request(json!({"action":"type","text":"Hello"}))
        .unwrap_err();
    assert_eq!(error.code, "HELPER_TIMEOUT");
    assert!(start.elapsed() < Duration::from_millis(500));
    assert_eq!(
        helper
            .request(json!({"action":"press","key":"Enter"}))
            .unwrap_err()
            .code,
        "HELPER_EOF"
    );
}

#[test]
fn local_script_pins_epoch_until_completion_and_releases_it_after_failure() {
    let file = File(std::env::temp_dir().join(format!(
        "mcc-script-epoch-{}.py",
        copis_chrome::protocol::random_id().unwrap()
    )));
    // A pause followed by resume races between the script's guard and input.
    std::fs::write(&file.0, r#"#!/usr/bin/env python3
import sys,json
bounds={'x':0,'y':0,'width':800,'height':600}
window={'windowId':42,'pid':123,'title':'test','bounds':bounds}
current_epoch=0
guards=0
for line in sys.stdin:
 r=json.loads(line); action=r['action']; data={}; error=None
 if action=='permissions': data={'screenRecording':True,'accessibility':True}
 elif action=='windows': data={'windows':[window]}
 elif action=='window':
  if guards>=2: current_epoch=1
  data={'window':window}
 elif action=='observe':
  open(r['imagePath'],'wb').write(bytes([255,216,255,217]))
  data={'imagePath':r['imagePath'],'width':800,'height':600,'bounds':bounds,'capturedAtMs':1}
 elif action=='transport-state':
  guards+=1
  data={'inputEpoch':current_epoch,'paused':False,'recoveryRequired':False}
 elif action=='type':
  if r.get('expectedInputEpoch',current_epoch)!=current_epoch: error={'code':'USER_PAUSED','message':'epoch changed'}
  else: data={'sent':True}
 print(json.dumps({'id':r['id'],'ok':error is None,**({'error':error} if error else {'data':data})}),flush=True)
"#).unwrap();
    std::fs::set_permissions(&file.0, std::fs::Permissions::from_mode(0o700)).unwrap();
    let root = std::env::temp_dir().join(format!(
        "mcc-script-epoch-{}",
        copis_chrome::protocol::random_id().unwrap()
    ));
    std::fs::create_dir(&root).unwrap();
    let helper = Helper::with_timeout(&file.0, Duration::from_secs(10)).unwrap();
    let mut service = copis_chrome::service::Service::new(helper, root.clone());
    let connection = service
        .execute(json!({"action":"connect","windowId":42}))
        .unwrap();
    let error=service.execute(json!({"action":"script","connectionId":connection["connectionId"],"script":{"version":1,"steps":[{"action":"observe"},{"action":"type","text":"must not send"}]}})).unwrap_err();
    assert_eq!(error.code, "USER_PAUSED");
    let progress = error.receipt.unwrap();
    assert_eq!(progress["completedSteps"], 1);
    // Ordinary input after the failed script must not inherit its stale epoch.
    let receipt=service.execute(json!({"action":"type","connectionId":connection["connectionId"],"frameId":progress["frameId"],"text":"new user request"})).unwrap();
    assert_eq!(receipt["sent"], true);
    drop(service);
    std::fs::remove_dir_all(root).unwrap();
}
