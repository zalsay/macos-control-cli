#if SAFARIER_CONTROL_TESTING
import XCTest
import Foundation
import SafarierCore
@testable import Safarier

@MainActor final class ControlSemanticTests: XCTestCase {
    final class State {
        var clickCount = 0, screenshots = 0
        var waiting: CheckedContinuation<Data, Error>?
    }
    func testCancelDuringDecisionNeverClicksEvenIfCleanupFails() async throws {
        for cleanup in [true, false] {
            let state=State(), profile=UUID()
            let identity=AutomationTargetIdentity(profileID:profile,runnerInstanceID:UUID(),windowID:UUID(),pageID:UUID())
            let viewport=AutomationViewport(viewportWidthPoints:100,viewportHeightPoints:100,pixelWidth:100,pixelHeight:100,scaleX:1,scaleY:1,pageZoom:1,viewVersion:1)
            let ocr=SemanticOCRResult(status:"ok",items:[SemanticOCRItem(text:"保存",x:10,y:10,width:20,height:20,confidence:0.99)],truncated:false)
            let broker=ControlBroker(testSender: { request in
                switch request.action {
                case .openSession: return AutomationReply(requestID:request.requestID,outcome:.success(.sessionOpened(sessionID:String(repeating:"A",count:43),target:identity,viewport:viewport)))
                case .screenshot: state.screenshots += 1; return AutomationReply(requestID:request.requestID,outcome:.success(.snapshotWritten(path:"/not-read",viewport:viewport)))
                case .cancel: return AutomationReply(requestID:request.requestID,outcome:.success(.sessionClosed(CleanupReceipt(cleaned:cleanup,terminatedOwnedRunner:cleanup))))
                case .click: state.clickCount += 1; return AutomationReply(requestID:request.requestID,outcome:.success(.nativeDelivered(sequence:1,buttons:0,viewVersion:1)))
                default: throw AutomationError(code:.invalidRequest)
                }
            }, testConfig: { ControlDecisionConfig(endpoint:URL(string:"https://example.com")!,model:"fixture",key:"fixture") }, testOCR: { _,_ in ocr }, testDecision: { _,_,_ in try await withCheckedThrowingContinuation { state.waiting=$0 } })
            let (opened,ack)=await broker.handle(ControlRequest(requestID:UUID(),operation:.connect(profileID:profile)))
            let connection=try XCTUnwrap(JSONDecoder().decode(ControlBrokerReply.self,from:opened).connection)
            broker.acknowledgement(try XCTUnwrap(ack),received:true)
            let task=Task { await broker.handle(ControlRequest(requestID:UUID(),operation:.clickTarget(connection:connection,target:"保存"))) }
            while state.waiting == nil { await Task.yield() }
            let (cancelled,_) = await broker.handle(ControlRequest(requestID:UUID(),operation:.cancel(connection:connection)))
            let close=try JSONDecoder().decode(ControlBrokerReply.self,from:cancelled)
            XCTAssertEqual(close.status,cleanup ? "ok" : "error")
            state.waiting?.resume(returning:Data(#"{"model":"fixture","answers":{"target":{"type":"choice","choice":"t0","confidence":1,"probabilities":{"t0":1,"none":0}}}}"#.utf8))
            let (reply,_) = await task.value
            XCTAssertEqual(try JSONDecoder().decode(ControlBrokerReply.self,from:reply).status,"error")
            XCTAssertEqual(state.clickCount,0); XCTAssertEqual(state.screenshots,1)
        }
    }
    func testDisabledConfigSkipsSnapshotAndModel() async throws {
        let profile=UUID(), identity=AutomationTargetIdentity(profileID:profile,runnerInstanceID:UUID(),windowID:UUID(),pageID:UUID())
        let viewport=AutomationViewport(viewportWidthPoints:100,viewportHeightPoints:100,pixelWidth:100,pixelHeight:100,scaleX:1,scaleY:1,pageZoom:1,viewVersion:1)
        let state=State()
        let broker=ControlBroker(testSender: { request in
            if case .openSession = request.action { return AutomationReply(requestID:request.requestID,outcome:.success(.sessionOpened(sessionID:String(repeating:"A",count:43),target:identity,viewport:viewport))) }
            state.screenshots += 1; throw AutomationError(code:.invalidRequest)
        },testConfig: { throw ControlDecisionConfig.Failure.disabled },testDecision: { _,_,_ in XCTFail("network called"); throw ControlDecision.Failure.unavailable })
        let (opened,ack)=await broker.handle(ControlRequest(requestID:UUID(),operation:.connect(profileID:profile)))
        let connection=try XCTUnwrap(JSONDecoder().decode(ControlBrokerReply.self,from:opened).connection); broker.acknowledgement(try XCTUnwrap(ack),received:true)
        let (reply,_) = await broker.handle(ControlRequest(requestID:UUID(),operation:.clickTarget(connection:connection,target:"保存")))
        XCTAssertEqual(try JSONDecoder().decode(ControlBrokerReply.self,from:reply).error,"MODEL_DISABLED"); XCTAssertEqual(state.screenshots,0)
    }
    func testConfigParser() throws {
        let base = "default_model = \"fixture\"\n[models.fixture]\nenabled = true\nurl = \"https://example.com/decisions\"\nmodel = \"fixture/model\"\napi_key = \"fixture-only\"\n"
        XCTAssertNoThrow(try ControlDecisionConfig.parse(base))
        XCTAssertThrowsError(try ControlDecisionConfig.parse(base.replacingOccurrences(of:"enabled = true",with:"enabled = false"))) { error in
            guard case ControlDecisionConfig.Failure.disabled = error else { return XCTFail("wrong failure") }
        }
        XCTAssertThrowsError(try ControlDecisionConfig.parse(base + "model = \"duplicate\"\n"))
        XCTAssertThrowsError(try ControlDecisionConfig.parse(base.replacingOccurrences(of:"https://",with:"http://")))
    }
    func testOfflineTransportRequiresHTTP200() async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:dir) }
        let fixture=dir.appendingPathComponent("fake-curl")
        let config=ControlDecisionConfig(endpoint:URL(string:"https://example.com")!,model:"fixture",key:"fixture")
        for (status,success) in [(200,true),(302,false),(500,false)] {
            let script="#!/bin/sh\n/bin/cat >/dev/null\nprintf '%s\\n%d' '{}' \(status)\n"
            try Data(script.utf8).write(to:fixture); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:fixture.path)
            do {
                let data=try await ControlDecision.decideForTest(config:config,request:Data("{}".utf8),cancellation:ControlCancellation(),executable:fixture)
                XCTAssertTrue(success); XCTAssertEqual(data,Data("{}".utf8))
            } catch { XCTAssertFalse(success) }
        }
    }

    func testSuccessClicksOnceAndModelFailureNeverClicks() async throws {
        for success in [true,false] {
            let state=State(), profile=UUID(), identity=AutomationTargetIdentity(profileID:profile,runnerInstanceID:UUID(),windowID:UUID(),pageID:UUID())
            let viewport=AutomationViewport(viewportWidthPoints:100,viewportHeightPoints:100,pixelWidth:100,pixelHeight:100,scaleX:1,scaleY:1,pageZoom:1,viewVersion:1)
            let ocr=SemanticOCRResult(status:"ok",items:[SemanticOCRItem(text:"保存",x:10,y:10,width:20,height:20,confidence:0.99)],truncated:false)
            let broker=ControlBroker(testSender: { request in
                switch request.action {
                case .openSession: return AutomationReply(requestID:request.requestID,outcome:.success(.sessionOpened(sessionID:String(repeating:"A",count:43),target:identity,viewport:viewport)))
                case .screenshot: return AutomationReply(requestID:request.requestID,outcome:.success(.snapshotWritten(path:"/not-read",viewport:viewport)))
                case .click: state.clickCount += 1; return AutomationReply(requestID:request.requestID,outcome:.success(.nativeDelivered(sequence:1,buttons:0,viewVersion:1)))
                default: throw AutomationError(code:.invalidRequest)
                }
            },testConfig: { ControlDecisionConfig(endpoint:URL(string:"https://example.com")!,model:"fixture",key:"fixture") },testOCR: { _,_ in ocr },testDecision: { _,_,_ in
                guard success else { throw ControlDecision.Failure.unavailable }
                return Data(#"{"model":"fixture","answers":{"target":{"type":"choice","choice":"t0","confidence":1,"probabilities":{"t0":1,"none":0}}}}"#.utf8)
            })
            let (opened,ack)=await broker.handle(ControlRequest(requestID:UUID(),operation:.connect(profileID:profile)))
            let connection=try XCTUnwrap(JSONDecoder().decode(ControlBrokerReply.self,from:opened).connection); broker.acknowledgement(try XCTUnwrap(ack),received:true)
            let (reply,_) = await broker.handle(ControlRequest(requestID:UUID(),operation:.clickTarget(connection:connection,target:"保存")))
            let decoded=try JSONDecoder().decode(ControlBrokerReply.self,from:reply)
            XCTAssertEqual(decoded.status,success ? "ok" : "error"); XCTAssertEqual(state.clickCount,success ? 1 : 0)
            if success { XCTAssertEqual(decoded.selection?.id,"t0"); XCTAssertEqual(decoded.selection?.text,"保存"); XCTAssertEqual(decoded.effectVerified,false); XCTAssertNotNil(decoded.timingMs) }
        }
    }

}
#endif
