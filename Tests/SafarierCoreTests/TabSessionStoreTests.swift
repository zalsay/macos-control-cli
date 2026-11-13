import XCTest
import Foundation
@testable import SafarierCore

final class TabSessionStoreTests: XCTestCase {
    func testSaveAndLoadSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SafarierWorkspace(root: root)
        let profile = Profile(name: "test-save", mode: .persistent)
        try workspace.profiles.insert(profile)

        let store = TabSessionStore(workspace: workspace, profileID: profile.id)
        XCTAssertNil(try store.load())

        let tabs = [
            SavedTab(url: URL(string: "https://example.com/a"), title: "Page A"),
            SavedTab(url: URL(string: "https://example.com/b"), title: "Page B"),
            SavedTab(url: nil, title: "起始页面"),
        ]
        let window1 = SavedSessionWindow(tabs: tabs, selectedTabIndex: 1)
        let session = SavedSession(windows: [window1])

        try store.save(session)

        let loaded = try store.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.windows.count, 1)
        XCTAssertEqual(loaded?.windows.first?.tabs.count, 3)
        XCTAssertEqual(loaded?.windows.first?.tabs[0].url, URL(string: "https://example.com/a"))
        XCTAssertEqual(loaded?.windows.first?.tabs[0].title, "Page A")
        XCTAssertEqual(loaded?.windows.first?.tabs[1].url, URL(string: "https://example.com/b"))
        XCTAssertEqual(loaded?.windows.first?.tabs[1].title, "Page B")
        XCTAssertNil(loaded?.windows.first?.tabs[2].url)
        XCTAssertEqual(loaded?.windows.first?.tabs[2].title, "起始页面")
        XCTAssertEqual(loaded?.windows.first?.selectedTabIndex, 1)
    }

    func testProfileIsolation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SafarierWorkspace(root: root)
        let profile1 = Profile(name: "profile-1", mode: .persistent)
        let profile2 = Profile(name: "profile-2", mode: .persistent)
        try workspace.profiles.insert(profile1)
        try workspace.profiles.insert(profile2)

        let store1 = TabSessionStore(workspace: workspace, profileID: profile1.id)
        let store2 = TabSessionStore(workspace: workspace, profileID: profile2.id)

        let session1 = SavedSession(windows: [
            SavedSessionWindow(tabs: [SavedTab(url: URL(string: "https://site-1.com"))], selectedTabIndex: 0)
        ])
        try store1.save(session1)

        XCTAssertEqual(try store1.load()?.windows.first?.tabs.first?.url, URL(string: "https://site-1.com"))
        XCTAssertNil(try store2.load())

        let session2 = SavedSession(windows: [
            SavedSessionWindow(tabs: [SavedTab(url: URL(string: "https://site-2.com"))], selectedTabIndex: 0)
        ])
        try store2.save(session2)

        XCTAssertEqual(try store1.load()?.windows.first?.tabs.first?.url, URL(string: "https://site-1.com"))
        XCTAssertEqual(try store2.load()?.windows.first?.tabs.first?.url, URL(string: "https://site-2.com"))
    }

    func testClearSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SafarierWorkspace(root: root)
        let profile = Profile(name: "test-clear", mode: .persistent)
        try workspace.profiles.insert(profile)

        let store = TabSessionStore(workspace: workspace, profileID: profile.id)
        let session = SavedSession(windows: [
            SavedSessionWindow(tabs: [SavedTab(url: URL(string: "https://example.com"))], selectedTabIndex: 0)
        ])
        try store.save(session)
        XCTAssertNotNil(try store.load())

        try store.clear()
        XCTAssertNil(try store.load())
        // Repeated clear does not throw error
        XCTAssertNoThrow(try store.clear())
    }

    func testWorkspaceArtifactCleanupRemovesSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SafarierWorkspace(root: root)
        let profile = Profile(name: "test-cleanup", mode: .persistent)
        try workspace.profiles.insert(profile)

        let store = TabSessionStore(workspace: workspace, profileID: profile.id)
        let session = SavedSession(windows: [
            SavedSessionWindow(tabs: [SavedTab(url: URL(string: "https://example.com"))], selectedTabIndex: 0)
        ])
        try store.save(session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.dataURL.path))

        workspace.removeRunnerArtifacts(for: profile.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.dataURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.lockURL.path))
    }

    func testCorruptDataCausesErrorOrReturnsNil() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SafarierWorkspace(root: root)
        let profile = Profile(name: "test-corrupt", mode: .persistent)
        try workspace.profiles.insert(profile)

        let store = TabSessionStore(workspace: workspace, profileID: profile.id)
        let session = SavedSession(windows: [
            SavedSessionWindow(tabs: [SavedTab(url: URL(string: "https://example.com"))], selectedTabIndex: 0)
        ])
        try store.save(session)
        try "corrupted json content".data(using: .utf8)!.write(to: store.dataURL)

        XCTAssertThrowsError(try store.load())
    }
}
