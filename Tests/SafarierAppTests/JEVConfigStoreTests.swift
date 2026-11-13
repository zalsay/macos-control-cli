import XCTest
@testable import Safarier

final class JEVConfigStoreTests: XCTestCase {
    func testCreateEditDisabledAndPreserveOtherModelsAndComments() throws {
        let dir=URL(fileURLWithPath:NSHomeDirectory(),isDirectory:true).appendingPathComponent("sfr-jev-test-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store=JEVConfigStore(directory:dir.path)
        let first=try store.read()
        try store.save(first, enabled:true, endpoint:"https://example.com/decisions", model:"example/model", newKey:"fixture-key")
        let created=try store.read(); XCTAssertTrue(created.enabled); XCTAssertEqual(created.model,"example/model")
        let path=dir.appendingPathComponent("models.toml")
        let added="\n# keep other model\n[models.other]\nenabled = false\nurl = \"https://other.example/decisions\"\nmodel = \"other/model\"\napi_key = \"other-fixture\"\n"
        try (String(contentsOf:path,encoding:.utf8)+added).write(to:path,atomically:false,encoding:.utf8)
        let current=try store.read()
        try store.save(current, enabled:false, endpoint:"https://example.com/decisions", model:"changed/model", newKey:"")
        let text=try String(contentsOf:path,encoding:.utf8)
        XCTAssertTrue(text.contains(added)); XCTAssertTrue(text.contains("api_key = \"fixture-key\""))
        XCTAssertFalse(try store.read().enabled)
        XCTAssertThrowsError(try ControlDecisionConfig.parse(text))
    }
    func testRejectsExternalChangeAndUnsafeFile() throws {
        let dir=URL(fileURLWithPath:NSHomeDirectory(),isDirectory:true).appendingPathComponent("sfr-jev-test-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store=JEVConfigStore(directory:dir.path)
        let first=try store.read()
        try store.save(first, enabled:true, endpoint:"https://example.com",model:"fixture",newKey:"fixture")
        let saved=try store.read(), path=dir.appendingPathComponent("models.toml")
        let original=try Data(contentsOf:path)
        try (original+Data("\n# external\n".utf8)).write(to:path)
        XCTAssertThrowsError(try store.save(saved,enabled:true,endpoint:"https://example.com",model:"new",newKey:""))
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:path.path)
        XCTAssertThrowsError(try store.read())
    }
    func testSavedDocumentIsValidTOMLForMCC() throws {
        let dir=URL(fileURLWithPath:NSHomeDirectory(),isDirectory:true).appendingPathComponent("sfr-jev-test-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store=JEVConfigStore(directory:dir.path)
        let snapshot=try store.read()
        try store.save(snapshot,enabled:true,endpoint:"https://example.com/a/b",model:"vendor/model",newKey:#"key"quoted\backslash"#)
        let text=try String(contentsOf:dir.appendingPathComponent("models.toml"),encoding:.utf8)
        XCTAssertTrue(text.contains(#"url = "https://example.com/a/b""#))
        XCTAssertTrue(text.contains(#"model = "vendor/model""#))
        XCTAssertTrue(text.contains(#"api_key = "key\"quoted\\backslash""#))
        XCTAssertFalse(text.contains(#"\/"#))
        let probe=Process();probe.executableURL=URL(fileURLWithPath:"/usr/bin/env");probe.arguments=["python3","-c","import tomllib"]
        probe.standardOutput=FileHandle.nullDevice;probe.standardError=FileHandle.nullDevice
        do { try probe.run() } catch { throw XCTSkip("python3 with tomllib is unavailable") }
        probe.waitUntilExit();if probe.terminationStatus != 0 { throw XCTSkip("python3 with tomllib is unavailable") }
        let task=Process();task.executableURL=URL(fileURLWithPath:"/usr/bin/env")
        task.arguments=["python3","-c",#"import sys,tomllib; x=tomllib.load(open(sys.argv[1],'rb')); m=x['models'][x['default_model']]; assert m['url']=='https://example.com/a/b'; assert m['model']=='vendor/model'; assert m['api_key']=='key\"quoted\\backslash'"#,dir.appendingPathComponent("models.toml").path]
        task.standardOutput=FileHandle.nullDevice;task.standardError=FileHandle.nullDevice
        try task.run();task.waitUntilExit();XCTAssertEqual(task.terminationStatus,0)
    }

    func testSymlinkHardlinkAndMCCLockAreRejected() throws {
        let root=URL(fileURLWithPath:NSHomeDirectory(),isDirectory:true).appendingPathComponent("sfr-jev-test-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=JEVConfigStore(directory:root.path), first=try store.read()
        try store.save(first,enabled:true,endpoint:"https://example.com",model:"fixture",newKey:"fixture")
        let path=root.appendingPathComponent("models.toml"), linked=root.appendingPathComponent("linked")
        try FileManager.default.linkItem(at:path,to:linked)
        XCTAssertThrowsError(try store.read())
        try FileManager.default.removeItem(at:linked)
        let snapshot=try store.read()
        FileManager.default.createFile(atPath:root.appendingPathComponent("config.lock").path,contents:Data())
        XCTAssertThrowsError(try store.save(snapshot,enabled:true,endpoint:"https://example.com",model:"changed",newKey:""))
        try FileManager.default.removeItem(at:root.appendingPathComponent("config.lock"))
        try FileManager.default.moveItem(at:path,to:linked)
        try FileManager.default.createSymbolicLink(at:path,withDestinationURL:linked)
        XCTAssertThrowsError(try store.read())
    }

}
