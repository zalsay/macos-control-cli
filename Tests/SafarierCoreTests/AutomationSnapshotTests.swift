import Foundation
import Darwin
import XCTest
@testable import SafarierCore
final class AutomationSnapshotTests: XCTestCase {
    func testSnapshotCases() throws {
        let parent = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent(".build/automation-snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { _ = rmdir(root.path) }
        XCTAssertGreaterThan(try AutomationSnapshotCases.run(base: root), 0)
    }
}
