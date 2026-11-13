import XCTest
@testable import SafarierCore

final class SemanticSelectionTests: XCTestCase {
    func testDecisionUsesOnlyLabelsAndRejectsMalformedResults() throws {
        let ocr = SemanticOCRResult(status: "ok", items: [SemanticOCRItem(text: "保存", x: 10, y: 20, width: 100, height: 40, confidence: 0.99), SemanticOCRItem(text: "取消", x: 200, y: 20, width: 100, height: 40, confidence: 0.99)], truncated: false)
        let request = try SemanticSelection.request(target: "保存", model: "fixture/model", ocr: ocr)
        let payload = String(decoding: request, as: UTF8.self)
        XCTAssertFalse(payload.contains("bbox")); XCTAssertFalse(payload.contains("center")); XCTAssertFalse(payload.contains("path"))
        let good = #"{"model":"fixture/model","answers":{"target":{"type":"choice","choice":"t0","confidence":0.985,"probabilities":{"t0":0.99,"t1":0.005,"none":0.005}}}}"#
        let point = try SemanticSelection.select(response: Data(good.utf8), model: "fixture/model", ocr: ocr)
        XCTAssertEqual(point.point.x, 60); XCTAssertEqual(point.point.y, 40)
        for bad in [good.replacingOccurrences(of: "0.99", with: "true"), good.replacingOccurrences(of: "0.985", with: "0.4"), good.replacingOccurrences(of: #""choice":"t0""#, with: #""choice":"none""#), #"{"model":"fixture/model","model":"fixture/model"}"#] {
            XCTAssertThrowsError(try SemanticSelection.select(response: Data(bad.utf8), model: "fixture/model", ocr: ocr))
        }
        XCTAssertThrowsError(try SemanticSelection.select(response: Data(repeating: 0x20, count: 65_537), model: "fixture/model", ocr: ocr))
        XCTAssertThrowsError(try SemanticSelection.request(target: "保存", model: "fixture/model", ocr: .unavailable))
    }
    func testTargetCommandRoundTripAndInvalidInputs() throws {
        let connection=UUID()
        let command=try ControlCLIParser.parse(["click-target","--connection",connection.uuidString,"--target","保存"])
        let original=ControlRequest(requestID:UUID(),operation:command.operation)
        XCTAssertEqual(try ControlProtocol.decodeRequest(ControlProtocol.encodeRequest(original)),original)
        for target in ["", "  ", "bad\nvalue", String(repeating:"a",count:513)] {
            XCTAssertThrowsError(try ControlCLIParser.parse(["click-target","--connection",connection.uuidString,"--target",target]))
        }
    }
    func testDecisionRejectsNoneAmbiguityAndWeakOCR() throws {
        let weak=SemanticOCRResult(status:"ok",items:[SemanticOCRItem(text:"保存",x:1,y:1,width:5,height:5,confidence:0.7)],truncated:false)
        let good=SemanticOCRResult(status:"ok",items:[SemanticOCRItem(text:"保存",x:1,y:1,width:5,height:5,confidence:0.99)],truncated:false)
        let certain = #"{"model":"fixture","answers":{"target":{"type":"choice","choice":"t0","confidence":1,"probabilities":{"t0":1,"none":0}}}}"#
        let none = #"{"model":"fixture","answers":{"target":{"type":"choice","choice":"none","confidence":1,"probabilities":{"t0":0,"none":1}}}}"#
        let ambiguous = #"{"model":"fixture","answers":{"target":{"type":"choice","choice":"t0","confidence":0.8,"probabilities":{"t0":0.9,"none":0.1}}}}"#
        XCTAssertThrowsError(try SemanticSelection.select(response:Data(certain.utf8),model:"fixture",ocr:weak))
        XCTAssertThrowsError(try SemanticSelection.select(response:Data(none.utf8),model:"fixture",ocr:good))
        XCTAssertThrowsError(try SemanticSelection.select(response:Data(ambiguous.utf8),model:"fixture",ocr:good))
    }

}
