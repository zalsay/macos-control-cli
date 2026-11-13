import XCTest
import Foundation
@testable import Safarier

#if SAFARIER_BOUND_LOCAL_CANDIDATE && SAFARIER_INTERNAL_TEST_APP
private final class SnapshotFrame: NSObject {
    @objc dynamic var webView: NSObject?
    @objc dynamic var isMainFrame = true
    @objc dynamic var request: NSURLRequest
    @objc(_documentIdentifier) var documentID: NSUUID?
    init(view: NSObject, url: URL, document: NSUUID) {
        webView = view; request = NSURLRequest(url: url); documentID = document
    }
}
private final class SnapshotView: NSObject {
    var handle = NSObject()
    var frame: SnapshotFrame!
    var pending: ((AnyObject?) -> Void)?
    var immediate = true
    @objc(_mainFrame) func mainFrame() -> NSObject { handle }
    @objc(_frameInfoFromHandle:completionHandler:)
    func frameInfo(_ handle: NSObject, completion: @escaping (AnyObject?) -> Void) {
        if immediate { completion(frame) } else { pending = completion }
    }
}

@MainActor final class RegisteredSameDocumentTests: XCTestCase {
    private let source = URL(string: "https://example.com/start")!
    private let target = URL(string: "https://example.com/search#ai")!

    func testSameURLReplaceRecordsSequenceButWaitsForDifferentURL() async throws {
        let view = SnapshotView(); view.frame = SnapshotFrame(view: view, url: source, document: NSUUID())
        let baseline = try await OwnedBrowserAutomationPage.registeredFrameSnapshot(view: view, source: source, deadline: .now + .seconds(1), valid: { true })
        let permit = OwnedBrowserAutomationPage.RegisteredNativePermit(source: source, epoch: 4)
        XCTAssertTrue(permit.recordSameDocument(view: view, expectedView: view, epoch: 4, abi: true, type: 2, request: source, current: source, baseline: baseline))
        XCTAssertEqual(permit.sameDocumentSequence, 1)
        XCTAssertFalse(permit.sameDocumentReady)
        XCTAssertFalse(permit.acceptsSameDocument(snapshot: baseline, baseline: baseline, sequence: 1, epoch: 4, current: source, deadline: .now + .seconds(1)))
        XCTAssertFalse(permit.allowsFullNavigation)
        XCTAssertTrue(permit.recordSameDocument(view: view, expectedView: view, epoch: 4, abi: true, type: 1, request: target, current: target, baseline: baseline))
        XCTAssertEqual(permit.sameDocumentSequence, 2)
        XCTAssertTrue(permit.sameDocumentReady)
        view.frame.request = NSURLRequest(url: target)
        let post = try await OwnedBrowserAutomationPage.registeredFrameSnapshot(view: view, source: target, deadline: .now + .seconds(1), valid: { true })
        XCTAssertTrue(permit.acceptsSameDocument(snapshot: post, baseline: baseline, sequence: 2, epoch: 4, current: target, deadline: .now + .seconds(1)))
    }

    func testSnapshotAndLatestCandidateUseRealObjects() async throws {
        let view = SnapshotView(); let document = NSUUID()
        view.frame = SnapshotFrame(view: view, url: source, document: document)
        let before = try await OwnedBrowserAutomationPage.registeredFrameSnapshot(view: view, source: source, deadline: .now + .seconds(1), valid: { true })
        let permit = OwnedBrowserAutomationPage.RegisteredNativePermit(source: source, epoch: 4)
        XCTAssertTrue(permit.allowsFullNavigation)
        let intermediate = URL(string: "https://example.com/replace")!
        XCTAssertTrue(permit.recordSameDocument(view: view, expectedView: view, epoch: 4, abi: true, type: 2, request: intermediate, current: intermediate, baseline: before))
        XCTAssertFalse(permit.allowsFullNavigation)
        let first = permit.sameDocumentSequence
        XCTAssertTrue(permit.recordSameDocument(view: view, expectedView: view, epoch: 4, abi: true, type: 1, request: target, current: target, baseline: before))
        XCTAssertFalse(permit.acceptsSameDocument(snapshot: before, baseline: before, sequence: permit.sameDocumentSequence, epoch: 4, current: target, deadline: .now + .seconds(1)))
        view.frame.request = NSURLRequest(url: target)
        let after = try await OwnedBrowserAutomationPage.registeredFrameSnapshot(view: view, source: target, deadline: .now + .seconds(1), valid: { true })
        XCTAssertFalse(permit.acceptsSameDocument(snapshot: after, baseline: before, sequence: first, epoch: 4, current: target, deadline: .now + .seconds(1)))
        XCTAssertTrue(permit.acceptsSameDocument(snapshot: after, baseline: before, sequence: permit.sameDocumentSequence, epoch: 4, current: target, deadline: .now + .seconds(1)))
        view.handle = NSObject()
        let changedFrame = try await OwnedBrowserAutomationPage.registeredFrameSnapshot(view: view, source: target, deadline: .now + .seconds(1), valid: { true })
        XCTAssertFalse(permit.acceptsSameDocument(snapshot: changedFrame, baseline: before, sequence: permit.sameDocumentSequence, epoch: 4, current: target, deadline: .now + .seconds(1)))
        view.handle = before.handle
        view.frame.documentID = NSUUID()
        let changed = try await OwnedBrowserAutomationPage.registeredFrameSnapshot(view: view, source: target, deadline: .now + .seconds(1), valid: { true })
        XCTAssertFalse(permit.acceptsSameDocument(snapshot: changed, baseline: before, sequence: permit.sameDocumentSequence, epoch: 4, current: target, deadline: .now + .seconds(1)))
    }

    func testRejectsInvalidCandidateAndExpiredOrReleasedPermit() async throws {
        let view = SnapshotView(); view.frame = SnapshotFrame(view: view, url: source, document: NSUUID())
        let snapshot = try await OwnedBrowserAutomationPage.registeredFrameSnapshot(view: view, source: source, deadline: .now + .seconds(1), valid: { true })
        let permit = OwnedBrowserAutomationPage.RegisteredNativePermit(source: source, epoch: 4)
        XCTAssertFalse(permit.recordSameDocument(view: NSObject(), expectedView: view, epoch: 4, abi: true, type: 1, request: target, current: target, baseline: snapshot))
        XCTAssertFalse(permit.recordSameDocument(view: view, expectedView: view, epoch: 5, abi: true, type: 1, request: target, current: target, baseline: snapshot))
        XCTAssertFalse(permit.recordSameDocument(view: view, expectedView: view, epoch: 4, abi: false, type: 1, request: target, current: target, baseline: snapshot))
        XCTAssertFalse(permit.recordSameDocument(view: view, expectedView: view, epoch: 4, abi: true, type: 3, request: target, current: target, baseline: snapshot))
        XCTAssertFalse(permit.recordSameDocument(view: view, expectedView: view, epoch: 4, abi: true, type: 1, request: nil, current: target, baseline: snapshot))
        XCTAssertFalse(permit.recordSameDocument(view: view, expectedView: view, epoch: 4, abi: true, type: 1, request: URL(string: "https://elsewhere.example/")!, current: URL(string: "https://elsewhere.example/")!, baseline: snapshot))
        XCTAssertFalse(permit.recordSameDocument(view: view, expectedView: view, epoch: 4, abi: true, type: 1, request: target, current: source, baseline: snapshot))
        XCTAssertTrue(permit.recordSameDocument(view: view, expectedView: view, epoch: 4, abi: true, type: 1, request: target, current: target, baseline: snapshot))
        view.frame.request = NSURLRequest(url: target)
        let current = try await OwnedBrowserAutomationPage.registeredFrameSnapshot(view: view, source: target, deadline: .now + .seconds(1), valid: { true })
        XCTAssertTrue(permit.acceptsSameDocument(snapshot: current, baseline: snapshot, sequence: permit.sameDocumentSequence, epoch: 4, current: target, deadline: .now + .seconds(1)))
        permit.decision = { _ in }
        XCTAssertFalse(permit.recordSameDocument(view: view, expectedView: view, epoch: 4, abi: true, type: 1, request: target, current: target, baseline: snapshot))
        XCTAssertFalse(permit.acceptsSameDocument(snapshot: current, baseline: snapshot, sequence: permit.sameDocumentSequence, epoch: 4, current: target, deadline: .now + .seconds(1)))
        permit.decision = nil
        XCTAssertFalse(permit.acceptsSameDocument(snapshot: current, baseline: snapshot, sequence: permit.sameDocumentSequence, epoch: 4, current: target, deadline: .now - .seconds(1)))
        permit.releaseForNavigation()
        XCTAssertFalse(permit.acceptsSameDocument(snapshot: current, baseline: snapshot, sequence: permit.sameDocumentSequence, epoch: 4, current: target, deadline: .now + .seconds(1)))
    }

    func testSnapshotRejectsMissingDocumentAndLateCallback() async throws {
        let view = SnapshotView(); view.frame = SnapshotFrame(view: view, url: source, document: NSUUID())
        view.frame.documentID = nil
        do { _ = try await OwnedBrowserAutomationPage.registeredFrameSnapshot(view: view, source: source, deadline: .now + .seconds(1), valid: { true }); XCTFail("missing document") } catch {}
        view.frame.documentID = NSUUID(); view.immediate = false
        do { _ = try await OwnedBrowserAutomationPage.registeredFrameSnapshot(view: view, source: source, deadline: .now + .milliseconds(30), valid: { true }); XCTFail("deadline") } catch {}
        view.pending?(view.frame)
    }

    func testCancelledSnapshotIgnoresLateCompletion() async throws {
        let view = SnapshotView(); view.frame = SnapshotFrame(view: view, url: source, document: NSUUID()); view.immediate = false
        let task = Task { try await OwnedBrowserAutomationPage.registeredFrameSnapshot(view: view, source: source, deadline: .now + .seconds(1), valid: { true }) }
        let cutoff = ContinuousClock.now + .seconds(1)
        while view.pending == nil, ContinuousClock.now < cutoff { await Task.yield() }
        guard view.pending != nil else { task.cancel(); XCTFail("completion was not registered"); return }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled snapshot") } catch {}
        view.pending?(view.frame)
        await Task.yield()
        XCTAssertTrue(task.isCancelled)
    }

    func testSnapshotRechecksValidityAfterAsyncReply() async throws {
        let view = SnapshotView(); view.frame = SnapshotFrame(view: view, url: source, document: NSUUID()); view.immediate = false
        var valid = true
        let task = Task { try await OwnedBrowserAutomationPage.registeredFrameSnapshot(view: view, source: source, deadline: .now + .seconds(1), valid: { valid }) }
        let cutoff = ContinuousClock.now + .seconds(1)
        while view.pending == nil, ContinuousClock.now < cutoff { await Task.yield() }
        guard let completion = view.pending else { task.cancel(); XCTFail("completion was not registered"); return }
        valid = false; completion(view.frame)
        do { _ = try await task.value; XCTFail("invalidated snapshot") } catch {}
    }

    func testNewCallbackDuringSnapshotInvalidatesEarlierSequence() async throws {
        let view = SnapshotView(); view.frame = SnapshotFrame(view: view, url: source, document: NSUUID())
        let baseline = try await OwnedBrowserAutomationPage.registeredFrameSnapshot(view: view, source: source, deadline: .now + .seconds(1), valid: { true })
        let permit = OwnedBrowserAutomationPage.RegisteredNativePermit(source: source, epoch: 4)
        let first = URL(string: "https://example.com/replace")!
        XCTAssertTrue(permit.recordSameDocument(view: view, expectedView: view, epoch: 4, abi: true, type: 2, request: first, current: first, baseline: baseline))
        let oldSequence = permit.sameDocumentSequence
        view.frame.request = NSURLRequest(url: first); view.immediate = false
        let task = Task { try await OwnedBrowserAutomationPage.registeredFrameSnapshot(view: view, source: first, deadline: .now + .seconds(1), valid: { true }) }
        let cutoff = ContinuousClock.now + .seconds(1)
        while view.pending == nil, ContinuousClock.now < cutoff { await Task.yield() }
        guard let completion = view.pending else { task.cancel(); XCTFail("completion was not registered"); return }
        XCTAssertTrue(permit.recordSameDocument(view: view, expectedView: view, epoch: 4, abi: true, type: 1, request: target, current: target, baseline: baseline))
        completion(view.frame)
        let oldSnapshot = try await task.value
        XCTAssertFalse(permit.acceptsSameDocument(snapshot: oldSnapshot, baseline: baseline, sequence: oldSequence, epoch: 4, current: target, deadline: .now + .seconds(1)))
        view.immediate = true; view.frame.request = NSURLRequest(url: target)
        let latest = try await OwnedBrowserAutomationPage.registeredFrameSnapshot(view: view, source: target, deadline: .now + .seconds(1), valid: { true })
        XCTAssertTrue(permit.acceptsSameDocument(snapshot: latest, baseline: baseline, sequence: permit.sameDocumentSequence, epoch: 4, current: target, deadline: .now + .seconds(1)))
    }
}
#endif
