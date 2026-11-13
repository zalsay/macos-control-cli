import Foundation
import Darwin
import XCTest
@testable import SafarierCore
final class ArtifactBaseTests: XCTestCase {
    func testCases() throws {
        guard let path = ProcessInfo.processInfo.environment["ARTIFACT_BASE_FIXTURE"] else { throw XCTSkip("private fixture not configured") }
        XCTAssertGreaterThan(try ArtifactBaseCases.run(root: URL(fileURLWithPath: path, isDirectory: true)), 0)
    }
}
