import Foundation
import Darwin

func require(_ value: Bool, _ message: String) { if !value { fputs("FAIL: \(message)\n",stderr); exit(1) } }
func expect(_ code: String, _ body: () throws -> Void) {
    do { try body(); require(false,"expected \(code)") }
    catch let error as HelperFailure { require(error.code == code,"got \(error.code), expected \(code)"); require(!error.message.contains("hidden@example.invalid"),"private metadata leaked") }
    catch { require(false,"unexpected error") }
}
let fm=FileManager.default
let root=fm.temporaryDirectory.appendingPathComponent("mcc-profile-\(UUID().uuidString)",isDirectory:true)
try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
defer {try? fm.removeItem(at:root)}
func directory(_ name:String) throws { try fm.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:false) }
func state(_ entries:[String:Any]) throws {
    let value:[String:Any] = ["profile":["info_cache":entries],"os_crypt":["encrypted_key":"never-forward-private"]]
    try JSONSerialization.data(withJSONObject:value).write(to:root.appendingPathComponent("Local State"))
}
try directory("Default");try directory("Profile 2")
try state(["Default":["name":"Personal","user_name":"hidden@example.invalid"],"Profile 2":["name":"mcc","gaia_id":"private"]])
let selected=try resolveChromeProfile(name:"mcc",dataRoot:root)
require(selected.name=="mcc" && selected.directory=="Profile 2","display name must resolve to real directory")
require(selected.json["path"] as? String == root.appendingPathComponent("Profile 2").path,"wrong profile path")
require(Set(selected.json.keys)==Set(["name","directory","path"]),"extra private metadata on wire")
try selected.revalidate()
expect("PROFILE_NOT_FOUND") { _=try resolveChromeProfile(name:"MCC",dataRoot:root) }
expect("PROFILE_NOT_FOUND") { _=try resolveChromeProfile(name:"missing",dataRoot:root) }
expect("INVALID_ARGUMENT") { _=try resolveChromeProfile(name:" mcc",dataRoot:root) }
expect("INVALID_ARGUMENT") { _=try resolveChromeProfile(name:String(repeating:"x",count:129),dataRoot:root) }
try state(["Default":["name":"mcc"],"Profile 2":["name":"mcc"]])
expect("PROFILE_AMBIGUOUS") { _=try resolveChromeProfile(name:"mcc",dataRoot:root) }
for key in ["../outside","/tmp/outside","a/b","a\\b",".","..","Guest Profile","System Profile"] {
    try state([key:["name":"mcc"]])
    expect("PROFILE_INVALID") { _=try resolveChromeProfile(name:"mcc",dataRoot:root) }
}
try state(["No Such Profile":["name":"mcc"]])
expect("PROFILE_UNAVAILABLE") { _=try resolveChromeProfile(name:"mcc",dataRoot:root) }
require(!fm.fileExists(atPath:root.appendingPathComponent("No Such Profile").path),"must not create profile")
try fm.createSymbolicLink(at:root.appendingPathComponent("Link"),withDestinationURL:root.appendingPathComponent("Default"))
try state(["Link":["name":"mcc"]])
expect("PROFILE_UNAVAILABLE") { _=try resolveChromeProfile(name:"mcc",dataRoot:root) }
try state(["Profile 2":["name":"mcc"]])
try fm.moveItem(at:root.appendingPathComponent("Profile 2"),to:root.appendingPathComponent("Previous"))
try directory("Profile 2")
expect("PROFILE_CHANGED") {try selected.revalidate()}
let current=try resolveChromeProfile(name:"mcc",dataRoot:root)
try state(["Profile 2":["name":"other"]])
expect("PROFILE_CHANGED") {try current.revalidate()}
let metadata=root.appendingPathComponent("Local State")
try Data("invalid hidden@example.invalid".utf8).write(to:metadata)
expect("PROFILE_METADATA_INVALID") {_=try resolveChromeProfile(name:"mcc",dataRoot:root)}
try fm.removeItem(at:metadata)
try fm.createSymbolicLink(at:metadata,withDestinationURL:root.appendingPathComponent("Previous"))
expect("PROFILE_METADATA_INVALID") {_=try resolveChromeProfile(name:"mcc",dataRoot:root)}
try fm.removeItem(at:metadata)
_ = fm.createFile(atPath:metadata.path,contents:Data())
let large=try FileHandle(forWritingTo:metadata);try large.truncate(atOffset:32*1024*1024+1);try large.close()
expect("PROFILE_METADATA_INVALID") {_=try resolveChromeProfile(name:"mcc",dataRoot:root)}
try state(["Profile 2":["name":"mcc"]])
let profile=try resolveChromeProfile(name:"mcc",dataRoot:root)
let markerPath=root.appendingPathComponent("mcc-profile-\(UUID().uuidString.lowercased()).html").path
let markerURL=try createChromeProfileMarker(path:markerPath)
let marker=markerURL.absoluteString
let permissions=try fm.attributesOfItem(atPath:markerPath)[.posixPermissions] as? NSNumber
require(permissions?.intValue==0o600,"marker file must be private")
expect("PROFILE_MARKER_FAILED") {_=try createChromeProfileMarker(path:markerPath)}
let argv=try chromeProfileLaunchArguments(application:URL(fileURLWithPath:"/Applications/Google Chrome.app"),profile:profile,marker:marker)
require(argv.contains("--profile-directory=Profile 2") && argv.contains("--user-data-dir=\(root.path)"),"must launch correct existing data/profile directory")
require(argv.contains("--new-window") && argv.last==marker,"must launch unique marker, not requested website yet")
require(argv.contains("--ignore-profile-directory-if-not-exists"),"must prevent Chrome from creating a missing profile")
require(!argv.contains(where:{$0.contains("hidden@example.invalid")}),"private metadata in argv")
expect("PROFILE_INVALID") {_=try chromeProfileLaunchArguments(application:URL(fileURLWithPath:"/Applications/Google Chrome.app"),profile:profile,marker:"https://example.com")}
let request=try NativeRequest.decode(["id":"profile","action":"chrome-start","profile":"mcc","profileMarkerPath":markerPath],scope:.desktop)
require(request.profile=="mcc","native protocol must retain requested display name")
for bad: Any in ["", " mcc", "mcc ", "x\n",String(repeating:"a",count:129),true,NSNull()] {
    expect("INVALID_ARGUMENT") {_=try NativeRequest.decode(["id":"profile","action":"chrome-start","profile":bad,"profileMarkerPath":markerPath],scope:.desktop)}
}
try fm.removeItem(at:metadata)
require(mkfifo(metadata.path,0o600)==0,"FIFO fixture failed")
expect("PROFILE_METADATA_INVALID") {_=try resolveChromeProfile(name:"mcc",dataRoot:root)}
try fm.removeItem(at:metadata)
let oldIdentity=ChromeWindowIdentity(pid:10,windowID:1)
func markerWindow(_ id:UInt32,_ bundle:String="com.google.Chrome")->ChromeWindow {
    ChromeWindow(target:TargetWindow(windowId:id,pid:10,bundleId:bundle),title:"",bounds:WindowBounds(x:0,y:25,width:800,height:600),layer:0,appName:"Chrome")
}
require(try selectProfileMarkerWindow(before:[oldIdentity],matches:[]) == nil,"empty marker may not select a window")
require(try selectProfileMarkerWindow(before:[oldIdentity],matches:[markerWindow(2)])?.windowId==2,"marker must bind new exact window")
expect("PROFILE_WINDOW_NOT_NEW") {_=try selectProfileMarkerWindow(before:[oldIdentity],matches:[markerWindow(1)])}
expect("PROFILE_WINDOW_AMBIGUOUS") {_=try selectProfileMarkerWindow(before:[oldIdentity],matches:[markerWindow(2),markerWindow(3)])}
expect("PROFILE_WINDOW_UNVERIFIED") {_=try selectProfileMarkerWindow(before:[oldIdentity],matches:[markerWindow(2,"other.app")])}
print("PASS: profile exact-name resolution, duplicate/missing/path/symlink/replacement rejection, bounded private metadata, launch argv and native protocol; no Chrome launched")
