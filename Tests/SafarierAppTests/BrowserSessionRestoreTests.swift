import XCTest
import AppKit
import WebKit
import SafarierCore
import SafarierWebKit
@testable import Safarier

@MainActor
final class BrowserSessionRestoreTests: XCTestCase {
    private func makeSession(profile: Profile, workspace: SafarierWorkspace) throws -> BrowserSession {
        _ = NSApplication.shared
        let factory = WebViewConfigurationFactory(credentials: InMemoryCredentialStore(), safariApplicationName: "Version/26.2 Safari/605.1.15")
        let output = try factory.make(profile: profile, proxy: nil, processLanguages: [])
        return BrowserSession(profile: profile, output: output, outboundDescription: "直连", diagnostics: SPIDiagnostics(), workspace: workspace)
    }

    private func spin(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testPersistentSessionRestoreOnStart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SafarierWorkspace(root: root)
        let profile = Profile(name: "persistent-restore", mode: .persistent)
        try workspace.profiles.insert(profile)

        let store = TabSessionStore(workspace: workspace, profileID: profile.id)
        let tabA = SavedTab(url: URL(string: "https://example.com/a"), title: "Page A")
        let tabB = SavedTab(url: URL(string: "https://example.com/b"), title: "Page B")
        let saved = SavedSession(windows: [
            SavedSessionWindow(tabs: [tabA, tabB], selectedTabIndex: 1)
        ])
        try store.save(saved)

        let session = try makeSession(profile: profile, workspace: workspace)
        defer {
            for controller in session.openControllers { controller.window.close() }
        }

        session.start(url: nil)
        spin(0.3)

        XCTAssertEqual(session.openControllers.count, 2)
        let tabGroup = session.openControllers.first?.window.tabGroup
        if let tabWindows = tabGroup?.windows {
            XCTAssertEqual(tabWindows.count, 2)
            XCTAssertTrue(tabGroup?.selectedWindow === session.openControllers.last?.window)
        }
    }

    func testRestoreThreeTabsWithLastSelected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SafarierWorkspace(root: root)
        let profile = Profile(name: "three-tabs", mode: .persistent)
        try workspace.profiles.insert(profile)

        let store = TabSessionStore(workspace: workspace, profileID: profile.id)
        let tabA = SavedTab(url: URL(string: "https://example.com/1"), title: "One")
        let tabB = SavedTab(url: URL(string: "https://example.com/2"), title: "Two")
        let tabC = SavedTab(url: URL(string: "https://example.com/3"), title: "Three")
        let saved = SavedSession(windows: [
            SavedSessionWindow(tabs: [tabA, tabB, tabC], selectedTabIndex: 2)
        ])
        try store.save(saved)

        let session = try makeSession(profile: profile, workspace: workspace)
        defer {
            for controller in session.openControllers { controller.window.close() }
        }

        session.start(url: nil)
        spin(0.5)

        XCTAssertEqual(session.openControllers.count, 3)

        let snapshot = session.snapshotOpenWindows()
        XCTAssertEqual(snapshot.count, 1)
        let restoredURLs = snapshot.first?.tabs.compactMap { $0.url?.absoluteString }
        XCTAssertEqual(restoredURLs, ["https://example.com/1", "https://example.com/2", "https://example.com/3"])
        XCTAssertEqual(snapshot.first?.selectedTabIndex, 2)

        // Closing the window via close button preserves all 3 tabs in store
        let firstWin = session.openControllers.first
        firstWin?.closeWindow(nil)
        spin(0.3)

        let reloaded = try store.load()
        XCTAssertNotNil(reloaded)
        XCTAssertEqual(reloaded?.windows.first?.tabs.count, 3)
    }

    func testEphemeralProfileDoesNotRestoreSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SafarierWorkspace(root: root)
        let profile = Profile(name: "ephemeral-no-restore", mode: .ephemeral)
        try workspace.profiles.insert(profile)

        // Artificially put a session file into sessions directory
        let store = TabSessionStore(workspace: workspace, profileID: profile.id)
        let saved = SavedSession(windows: [
            SavedSessionWindow(tabs: [SavedTab(url: URL(string: "https://example.com"))], selectedTabIndex: 0)
        ])
        try store.save(saved)

        let session = try makeSession(profile: profile, workspace: workspace)
        defer {
            for controller in session.openControllers { controller.window.close() }
        }

        // Ephemeral init should clear any prior session file
        XCTAssertNil(try store.load())

        session.start(url: nil)
        spin(0.2)

        XCTAssertEqual(session.openControllers.count, 1)
        XCTAssertNil(session.openControllers.first?.displayURL)
    }

    func testClosingWindowPreservesTabsInSavedSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SafarierWorkspace(root: root)
        let profile = Profile(name: "preserve-on-close", mode: .persistent)
        try workspace.profiles.insert(profile)

        let session = try makeSession(profile: profile, workspace: workspace)

        let win1 = session.openWindow(url: URL(string: "https://example.com/one"))
        _ = session.openTab(in: win1, url: URL(string: "https://example.com/two"))
        spin(0.1)

        // Trigger immediate save
        session.saveSessionState()

        let store = TabSessionStore(workspace: workspace, profileID: profile.id)
        let beforeClose = try store.load()
        XCTAssertNotNil(beforeClose)
        XCTAssertEqual(beforeClose?.windows.first?.tabs.count, 2)

        // Close window (closes all tabs)
        win1.closeWindow(nil)
        spin(0.4)

        // The session on disk must NOT have been erased to empty
        let afterClose = try store.load()
        XCTAssertNotNil(afterClose)
        XCTAssertEqual(afterClose?.windows.first?.tabs.count, 2)
    }

    #if SAFARIER_BOUND_LOCAL_CANDIDATE
    func testStartRegisteredInteractiveRestoresTabs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SafarierWorkspace(root: root)
        let profile = Profile(name: "reg-interactive-restore", mode: .persistent)
        try workspace.profiles.insert(profile)

        let store = TabSessionStore(workspace: workspace, profileID: profile.id)
        let tabA = SavedTab(url: URL(string: "https://example.com/alpha"), title: "Alpha")
        let tabB = SavedTab(url: URL(string: "https://example.com/beta"), title: "Beta")
        let saved = SavedSession(windows: [
            SavedSessionWindow(tabs: [tabA, tabB], selectedTabIndex: 0)
        ])
        try store.save(saved)

        let session = try makeSession(profile: profile, workspace: workspace)
        defer {
            for controller in session.openControllers { controller.window.close() }
        }

        // GUI launches runner with startRegisteredInteractive
        session.startRegisteredInteractive(url: nil)
        spin(0.3)

        XCTAssertEqual(session.openControllers.count, 2)
        XCTAssertEqual(session.openControllers.first?.displayURL?.absoluteString, "https://example.com/alpha")
    }
    #endif
}
