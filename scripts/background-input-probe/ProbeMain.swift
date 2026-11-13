import AppKit
import WebKit
import SafarierCore
import SafarierWebKit
import CryptoKit
import Carbon
import ObjectiveC
import SafarierObjCSupport

@MainActor
final class BackgroundProbe: NSObject, NSApplicationDelegate {
    let output: URL
    let mode: String
    let visibility: String
    let scenario: String
    var session: BrowserSession!
    var controller: BrowserWindowController!
    var webView: BrowserWebView!
    var driver: NativeEvents!
    var cases = [[String: Any]]()
    var observations = [[String: Any]]()
    var activations = [[String: Any]]()
    var initialSafety = [String: Any]()
    var latestState = [String: Any]()
    var observer: NSObjectProtocol?
    var timer: Timer?
    var finished = false
    var samples = [[String: Any]]()
    var externalPointerEvents = 0
    var ownGlobalPointerEvents = 0
    var pointerMonitor: Any?
    var localPointerMonitor: Any?
    var originalButtonsIMP: IMP?
    var originalKeyIMP: IMP?
    var cover: NSWindow?

    init(output: URL, mode: String, visibility: String, scenario: String) {
        self.output=output; self.mode=mode; self.visibility=visibility; self.scenario=scenario
        super.init()
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: output.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        originalButtonsIMP=class_getClassMethod(NSEvent.self,#selector(getter:NSEvent.pressedMouseButtons)).map{method_getImplementation($0)}
        originalKeyIMP=class_getInstanceMethod(NSApplication.self,#selector(getter:NSApplication.keyWindow)).map{method_getImplementation($0)}
        initialSafety=safety()
    }
    func sameImplementation(_ current: IMP?, _ expected: IMP?) -> Bool {
        guard let current, let expected else { return false }
        return unsafeBitCast(current, to: UInt.self) == unsafeBitCast(expected, to: UInt.self)
    }
    func safety() -> [String: Any] {
        let p=CGEvent(source:nil)?.location ?? .zero
        let f=NSWorkspace.shared.frontmostApplication
        var object:AnyObject?
        var detail:NSString?
        let cursorStatus=SFRGetObject(NSCursor.self,"currentSystemCursor",&object,&detail)
        let image=(object as? NSCursor)?.image.tiffRepresentation
        let shape=image.map{SHA256.hash(data:$0).map{String(format:"%02x",$0)}.joined()} ?? "unavailable"
        var inputSource="unavailable"
        if let source=TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let property=TISGetInputSourceProperty(source,kTISPropertyInputSourceID) {
            inputSource=Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
        }
        return ["hidKeyDown":Int(CGEventSource.counterForEventType(.hidSystemState,eventType:.keyDown)),"hidKeyUp":Int(CGEventSource.counterForEventType(.hidSystemState,eventType:.keyUp)),"hidFlagsChanged":Int(CGEventSource.counterForEventType(.hidSystemState,eventType:.flagsChanged)),"activationPolicy":NSApplication.shared.activationPolicy().rawValue,"keyboardInputSource":inputSource,"hardwareModifiers":CGEventSource.flagsState(.hidSystemState).rawValue,"cursorShape":shape,"cursorShapeStatus":cursorStatus.rawValue,"secureInput":IsSecureEventInputEnabled(),"cursorGuard":SFRBackgroundCursorProtectionIsInstalled(),"suppressedCursorWrites":SFRBackgroundCursorWritesSuppressed(),"cursorX":Double(p.x),"cursorY":Double(p.y),"frontPID":f?.processIdentifier ?? -1,"ownPID":ProcessInfo.processInfo.processIdentifier,"ownAppActive":NSApp?.isActive ?? false,"ownWindowKey":controller?.window.isKeyWindow ?? false,"time":ProcessInfo.processInfo.systemUptime]
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        observer=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] note in
            MainActor.assumeIsolated {
            guard let self else{return}
            let app=note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.activations.append(["pid":app?.processIdentifier ?? -1,"own":app?.processIdentifier == ProcessInfo.processInfo.processIdentifier,"time":ProcessInfo.processInfo.systemUptime])
            }
        }
        pointerMonitor=NSEvent.addGlobalMonitorForEvents(matching:[.mouseMoved,.leftMouseDown,.leftMouseUp,.leftMouseDragged,.scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
            guard let self else{return}
            if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(ProcessInfo.processInfo.processIdentifier){ self.ownGlobalPointerEvents += 1 }
            else { self.externalPointerEvents += 1 }
            }
        }
        localPointerMonitor=NSEvent.addLocalMonitorForEvents(matching:[.mouseMoved,.leftMouseDown,.leftMouseUp,.leftMouseDragged,.scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(ProcessInfo.processInfo.processIdentifier) {self?.ownGlobalPointerEvents += 1}
            }
            return event
        }
        timer=Timer.scheduledTimer(withTimeInterval:0.03,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else{return}; let sample = self.safety(); self.samples.append(sample)
                if self.scenario == "pointer-smoke" && ((sample["ownAppActive"] as? Bool ?? true) || (sample["ownWindowKey"] as? Bool ?? true) || self.ownGlobalPointerEvents != 0 || self.activations.contains(where: { $0["own"] as? Bool == true })) {
                    self.finish(error:"pointer smoke safety stop")
                } }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+55) { [weak self] in self?.finish(error:"watchdog timeout") }
        Task { await self.run() }
    }
    func pause(_ seconds: Double = 0.25) async { try? await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000)) }
    func read() async throws -> [String: Any] {
        try await driver?.drain()
        guard let state=try await webView.evaluateJavaScript("window.probeSnapshot()") as? [String: Any] else {throw NSError(domain:"probe",code:1)}
        latestState=state
        return state
    }
    func number(_ s:[String:Any],_ key:String)->Double{(s[key] as? NSNumber)?.doubleValue ?? -1}
    func record(_ name:String,_ passed:Bool,_ state:[String:Any],_ extra:[String:Any]=[:]){
        var row:[String:Any]=["name":name,"passed":passed,"safety":safety(),"state":state]
        for(k,v) in extra{row[k]=v};cases.append(row)
        print("CASE \(name): \(passed ? "PASS":"FAIL")")
    }
    func smokeCheck() throws {
        let state = safety()
        guard !finished, pointerMonitor != nil, localPointerMonitor != nil,
              !(state["ownAppActive"] as? Bool ?? true), !(state["ownWindowKey"] as? Bool ?? true),
              ownGlobalPointerEvents == 0, !activations.contains(where: { $0["own"] as? Bool == true }),
              driver == nil || driver.activityStatus == .OK else {
            throw NSError(domain:"pointer smoke safety stop",code:1)
        }
    }
    func smokeRecord(_ name: String, _ passed: Bool, _ state: [String: Any]) throws {
        record(name, passed, state)
        guard passed else { throw NSError(domain:"pointer smoke assertion: \(name)",code:1) }
        try smokeCheck()
    }
    func pointerSmoke(_ initial: [String: Any]) async throws {
        try smokeCheck()
        try smokeRecord("ready_background", !(safety()["ownAppActive"] as? Bool ?? true) && !(safety()["ownWindowKey"] as? Bool ?? true), initial)
        driver.move(280,70); await pause(); try smokeCheck(); var state=try await read(); try smokeCheck()
        try smokeRecord("hover",number(state,"hovers")>0 && (state["hoverColor"] as? String)=="rgb(40, 180, 100)",state)
        driver.move(760,550); await pause(); try smokeCheck(); state=try await read(); try smokeCheck()
        try smokeRecord("hover_exit",number(state,"hoverLeaves")>0 && (state["hoverColor"] as? String)=="rgb(221, 221, 221)",state)
        driver.move(620,260); await pause(); try smokeCheck()
        driver.press(620,260); await pause(0.3); try smokeCheck(); state=try await read(); try smokeCheck()
        try smokeRecord("held",driver.buttonMask==1,state)
        driver.move(700,260); await pause(0.3); try smokeCheck(); state=try await read(); try smokeCheck()
        let drag=(state["records"] as? [[String:Any]] ?? []).filter { $0["type"] as? String == "pointermove" && $0["id"] as? String == "customdrag" && number($0,"buttons")==1 }
        try smokeRecord("drag",number(state,"customDragMoves")>0 && !drag.isEmpty,state)
        driver.release(700,260); await pause(); try smokeCheck(); state=try await read(); try smokeCheck()
        let events=state["records"] as? [[String:Any]] ?? []
        let downs=events.filter { $0["type"] as? String == "pointerdown" && $0["id"] as? String == "customdrag" }
        let ups=events.filter { $0["type"] as? String == "pointerup" && $0["id"] as? String == "customdrag" }
        try smokeRecord("release",driver.buttonMask==0 && !ups.isEmpty && ups.allSatisfy { number($0,"buttons")==0 },state)
        try smokeRecord("trusted_pointer",!downs.isEmpty && (downs+drag+ups).allSatisfy { $0["trusted"] as? Bool == true },state)
        driver.closeActivity()
        let end=Date().addingTimeInterval(3)
        while !driver.activityClosed && Date()<end { await pause(0.03); try smokeCheck() }
        try smokeRecord("page_activity_restored",driver.activityClosed && driver.activityStatus == .OK,state)
        finish(error:nil)
    }
    func run() async {
        do {
            let profile=Profile(name:"Isolated background input probe",mode:.ephemeral,spi:[])
            let factory=WebViewConfigurationFactory(credentials:KeychainCredentialStore())
            let config=try factory.make(profile:profile,proxy:nil)
            session=BrowserSession(profile:profile,output:config,outboundDescription:"offline diagnostic only",diagnostics:SPIDiagnostics())
            webView=BrowserWebView(frame:NSRect(x:0,y:0,width:800,height:600),configuration:config.configuration)
            controller=BrowserWindowController(session:session,webView:webView,contentSize:NSSize(width:800,height:650))
            controller.window.setFrameOrigin(NSPoint(x:80,y:100))
            controller.window.animationBehavior = .none
            controller.window.ignoresMouseEvents = true // Physical clicks pass through this owned fixture.
            controller.window.orderBack(nil) // Never makeKey / activate / post to global input stream.
            controller.window.contentView?.layoutSubtreeIfNeeded()
            let fixture=Bundle.main.resourceURL!.appendingPathComponent("fixture.html")
            webView.loadFileURL(fixture,allowingReadAccessTo:fixture.deletingLastPathComponent())
            let deadline=Date().addingTimeInterval(15)
            var ready=false
            while Date()<deadline {
                await pause(0.1)
                if (try? await webView.evaluateJavaScript("window.__probeReady===true")) as? Bool == true {ready=true;break}
            }
            guard ready else {finish(error:"fixture failed to become ready");return}
            controller.updateState()
            await pause(0.7)
            if visibility == "occluded" {
                cover=NSWindow(contentRect:controller.window.frame,styleMask:[.borderless],backing:.buffered,defer:false)
                cover?.backgroundColor = .darkGray
                cover?.ignoresMouseEvents=true
                cover?.order(.above,relativeTo:controller.window.windowNumber)
            } else if visibility == "hidden" { controller.window.orderOut(nil) }
            let originalAppKeyWindow=NSApplication.shared.keyWindow
            driver=NativeEvents(webView:webView,window:controller.window,mode:mode)
            let activityDeadline=Date().addingTimeInterval(3)
            while !driver.activityReady && driver.activityStatus == .OK && Date()<activityDeadline{await pause(0.03)}
            guard driver.activityReady && driver.activityStatus == .OK else{finish(error:"background activity unavailable: \(driver.trace)");return}
            let s0=try await read()
            observations.append(["phase":"ready","safety":safety(),"state":s0,"webViewFlipped":webView.isFlipped,"viewClass":String(describing:type(of:webView)),"windowNumber":controller.window.windowNumber])
            if scenario == "pointer-smoke" { try await pointerSmoke(s0); return }
            record("ready_background",!(safety()["ownAppActive"] as? Bool ?? true) && !(safety()["ownWindowKey"] as? Bool ?? true),s0)

            driver.move(280,70); await pause(); var s=try await read()
            record("hover",number(s,"hovers")>0 && (s["hoverColor"] as? String)=="rgb(40, 180, 100)",s)
            let hoverEvents=(s["records"] as? [[String:Any]] ?? []).filter{$0["type"] as? String == "pointermove" && $0["id"] as? String == "hover"}
            record("hover_pointer_semantics",!hoverEvents.isEmpty && hoverEvents.allSatisfy{number($0,"buttons")==0 && number($0,"button")==(-1)},s)
            driver.move(760,550);await pause();s=try await read()
            record("hover_exit",number(s,"hoverLeaves")>0 && s["hoverColor"] as? String == "rgb(221, 221, 221)",s)
            driver.click(110,70); await pause(); s=try await read()
            record("click",number(s,"clicks")==1,s)
            driver.click(633,68); await pause(); s=try await read()
            record("checkbox_default_action",s["checkbox"] as? Bool == true,s)
            driver.click(110,70,count:2); await pause(); s=try await read()
            record("double_click",number(s,"doubles")==1,s)
            driver.click(140,160); _ = try await read()
            driver.type("native-123"); await pause(); s=try await read()
            record("text_ascii",s["text"] as? String == "native-123",s)
            driver.key("\u{8}",code:51); await pause(); s=try await read()
            record("backspace",s["text"] as? String == "native-12",s)
            driver.type("中文"); await pause(); s=try await read()
            record("text_unicode",s["text"] as? String == "native-12中文",s)
            let secureBefore=IsSecureEventInputEnabled()
            driver.click(550,114);await pause(0.1);_ = try await read()
            driver.type("probe");await pause();s=try await read()
            record("password_without_global_secure_input",number(s,"passwordLength")==5 && IsSecureEventInputEnabled()==secureBefore,s)
            driver.drag(NSPoint(x:51,y:260),NSPoint(x:420,y:260)); await pause(); s=try await read()
            record("range_drag",number(s,"range")>80,s)
            driver.drag(NSPoint(x:410,y:157),NSPoint(x:605,y:157)); await pause(); s=try await read()
            let sel=s["selection"] as? [Int] ?? []
            record("text_selection_drag",sel.count==2 && sel[1]>sel[0],s)
            driver.drag(NSPoint(x:620,y:260),NSPoint(x:730,y:260)); await pause(); s=try await read()
            record("custom_pointer_drag_buttons",number(s,"customDragMoves")>0 && number(s,"customDragSelectedLength")==0,s)
            driver.move(620,260);driver.press(620,260);await pause(0.3);s=try await read()
            let held=driver.buttonMask==1
            let buttonsMethod=class_getClassMethod(NSEvent.self,#selector(getter:NSEvent.pressedMouseButtons))!
            record("held_state_is_process_local",held && sameImplementation(method_getImplementation(buttonsMethod),originalButtonsIMP),s)
            driver.move(700,260);await pause(0.3);s=try await read()
            driver.release(700,260);await pause();s=try await read()
            let ups=(s["records"] as? [[String:Any]] ?? []).filter{$0["type"] as? String == "pointerup" && $0["id"] as? String == "customdrag"}
            record("held_state_releases_to_zero",driver.buttonMask==0 && !ups.isEmpty && ups.allSatisfy{number($0,"buttons")==0},s)
            driver.scroll(220,400,delta:-160); await pause(0.6); s=try await read()
            record("scroll_default_action",number(s,"scroll")>20,s)
            let events=s["records"] as? [[String:Any]] ?? []
            let nativeMouse=events.filter{["pointerdown","mousedown","mouseup","click"].contains($0["type"] as? String ?? "")}
            let downEvents=events.filter{["pointerdown","mousedown"].contains($0["type"] as? String ?? "")}
            record("pointer_down_buttons_semantics",!downEvents.isEmpty && downEvents.allSatisfy{number($0,"buttons")==1},s)
            let dragEvents=events.filter{$0["type"] as? String == "pointermove" && $0["id"] as? String == "customdrag" && number($0,"buttons")==1}
            record("drag_events_have_held_button",!dragEvents.isEmpty, s)
            record("native_mouse_events_trusted",!nativeMouse.isEmpty && nativeMouse.allSatisfy{$0["trusted"] as? Bool == true},s)
            record("no_unexpected_fixture_input",s["unexpectedInput"] as? Bool == false,s)
            if cases.allSatisfy({$0["passed"] as? Bool == true}),let image=try? await webView.takeSnapshot(configuration:nil),let data=image.tiffRepresentation,let rep=NSBitmapImageRep(data:data),let png=rep.representation(using:.png,properties:[:]){try? png.write(to:output.appendingPathComponent("page.png"))}
            driver.closeActivity()
            let endDeadline=Date().addingTimeInterval(3)
            while !driver.activityClosed && Date()<endDeadline{await pause(0.03)}
            let restored=try await read()
            record("page_activity_restored",driver.activityClosed && driver.activityStatus == .OK && restored["hasFocus"] as? Bool == false,restored)
            let keyMethod=class_getInstanceMethod(NSApplication.self,#selector(getter:NSApplication.keyWindow))!
            record("temporary_queries_restored",sameImplementation(method_getImplementation(keyMethod),originalKeyIMP) && sameImplementation(method_getImplementation(buttonsMethod),originalButtonsIMP) && NSApplication.shared.keyWindow === originalAppKeyWindow,restored)
            record("background_cursor_write_protection",mode=="stub" || SFRBackgroundCursorProtectionIsInstalled(),restored,["suppressedWrites":SFRBackgroundCursorWritesSuppressed()])
            await pause(0.3)
            finish(error:nil)
        } catch { finish(error:String(describing:error)) }
    }
    func finish(error:String?){
        guard !finished else{return};finished=true
        timer?.invalidate()
        driver?.closeActivity()
        let final=safety()
        let ownActivation=activations.contains{$0["own"] as? Bool == true} || samples.contains{$0["ownAppActive"] as? Bool == true}
        let cursorMoved=samples.contains{($0["cursorX"] as? Double) != (initialSafety["cursorX"] as? Double) || ($0["cursorY"] as? Double) != (initialSafety["cursorY"] as? Double)}
        let initialShape=initialSafety["cursorShape"] as? String ?? "unavailable"
        let shapeChanged=samples.contains{($0["cursorShape"] as? String ?? "unavailable") != initialShape}
        let externalKeyboardEvents=max(0,(final["hidKeyDown"] as? Int ?? 0)-(initialSafety["hidKeyDown"] as? Int ?? 0)) + max(0,(final["hidKeyUp"] as? Int ?? 0)-(initialSafety["hidKeyUp"] as? Int ?? 0))
        let externalModifierEvents=max(0,(final["hidFlagsChanged"] as? Int ?? 0)-(initialSafety["hidFlagsChanged"] as? Int ?? 0))
        let externalInputObserved=externalPointerEvents>0 || externalKeyboardEvents>0 || externalModifierEvents>0
        let idleShapeSafe=externalInputObserved || initialShape=="unavailable" || !shapeChanged
        let safetyRow:[String:Any]=["name":"no_global_input_or_activation","passed":!ownActivation && ownGlobalPointerEvents==0 && (!cursorMoved || externalInputObserved) && idleShapeSafe && pointerMonitor != nil && localPointerMonitor != nil,"ownActivationObserved":ownActivation,"cursorShapeChanged":shapeChanged,"cursorShapeObserved":initialShape != "unavailable","globalMonitorInstalled":pointerMonitor != nil,"localMonitorInstalled":localPointerMonitor != nil,"ownGlobalPointerEvents":ownGlobalPointerEvents,"externalPointerEvents":externalPointerEvents,"externalKeyboardEvents":externalKeyboardEvents,"externalModifierEvents":externalModifierEvents,"externalInputObserved":externalInputObserved,"fixtureIgnoresPhysicalClicks":controller?.window.ignoresMouseEvents ?? false,"cursorMovedDuringRun":cursorMoved,"sampleCount":samples.count,"cursorMotionAttribution":cursorMoved ? (externalInputObserved ? "external input counters observed; no own global events" : "unexplained") : "stable","initial":initialSafety,"final":final]
        cases.append(safetyRow)
        var result:[String:Any]=["mode":mode,"visibility":visibility,"scenario":scenario,"cases":cases,"observations":observations,"activations":activations,"samples":samples,"driverTrace":driver?.trace ?? [],"initial":initialSafety,"final":final,"allPassed":error==nil && cases.allSatisfy{$0["passed"] as? Bool == true},"scope":"tracked native-input regression probe; real Safarier BrowserWebView/BrowserWindowController; no production profile; no global event posting"]
        if let error{result["error"]=error}
        if let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]){try? data.write(to:output.appendingPathComponent("report.json"))}
        print("REPORT \(output.path) allPassed=\(result["allPassed"] ?? false)")
        if let pointerMonitor{NSEvent.removeMonitor(pointerMonitor)}
        if let localPointerMonitor{NSEvent.removeMonitor(localPointerMonitor)}
        if let observer{NSWorkspace.shared.notificationCenter.removeObserver(observer)}
        cover?.orderOut(nil)
        webView?.stopLoading()
        controller?.window.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2){NSApp.terminate(nil)}
    }
}

@main struct ProbeMain {
    @MainActor static func main(){
        let args=CommandLine.arguments
        func value(_ key:String,_ fallback:String)->String{guard let i=args.firstIndex(of:key),i+1<args.count else{return fallback};return args[i+1]}
        let earlyOutput=URL(fileURLWithPath:value("--output","/tmp/safarier-probe"))
        try? FileManager.default.createDirectory(at:earlyOutput,withIntermediateDirectories:true)
        try? "main_entered\n".write(to:earlyOutput.appendingPathComponent("bootstrap.log"),atomically:true,encoding:.utf8)
        let mode=value("--mode","stub"), visibility=value("--visibility","background"), scenario=value("--scenario","full")
        guard scenario == "full" || (scenario == "pointer-smoke" && mode == "fixed" && visibility == "background") else { print("invalid scenario"); return }
        let app=NSApplication.shared
        let probe=BackgroundProbe(output:URL(fileURLWithPath:value("--output","/tmp/safarier-probe")),mode:mode,visibility:visibility,scenario:scenario)
        app.setActivationPolicy(.accessory)
        app.delegate=probe
        app.run()
        withExtendedLifetime(probe){}
    }
}
