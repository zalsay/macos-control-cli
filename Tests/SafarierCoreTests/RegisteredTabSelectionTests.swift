import XCTest
@testable import SafarierCore

final class RegisteredTabSelectionTests: XCTestCase {
    func testOnlyOneUnambiguousGroupSelectsItsCurrentMember() throws {
        let group = UUID(), first = UUID(), second = UUID()
        let snapshot = RegisteredTabSelection.Group(id: group, members: [first, second], selected: second, overviewVisible: false)
        let guardState = try XCTUnwrap(RegisteredTabSelection(groups: [snapshot]))
        XCTAssertEqual(guardState.selectedWindow, second)
        XCTAssertTrue(guardState.validate(groups: [snapshot]))
        XCTAssertNil(RegisteredTabSelection(groups: [snapshot, .init(id: UUID(), members: [UUID()], selected: nil, overviewVisible: false)]))
        XCTAssertNil(RegisteredTabSelection(groups: [.init(id: group, members: [first, second], selected: nil, overviewVisible: false)]))
        XCTAssertNil(RegisteredTabSelection(groups: [.init(id: group, members: [first, first], selected: first, overviewVisible: false)]))
        XCTAssertNil(RegisteredTabSelection(groups: [.init(id: group, members: [first], selected: second, overviewVisible: false)]))
        XCTAssertNil(RegisteredTabSelection(groups: [.init(id: group, members: [first], selected: first, overviewVisible: true)]))
    }

    func testChangeRevokesGenerationEvenAfterRestoration() throws {
        let group = UUID(), first = UUID(), second = UUID()
        let original = RegisteredTabSelection.Group(id: group, members: [first, second], selected: first, overviewVisible: false)
        let guardState = try XCTUnwrap(RegisteredTabSelection(groups: [original]))
        let switched = RegisteredTabSelection.Group(id: group, members: [first, second], selected: second, overviewVisible: false)
        XCTAssertFalse(guardState.validate(groups: [switched]))
        XCTAssertFalse(guardState.validate(groups: [original]))
        let next = try XCTUnwrap(RegisteredTabSelection(groups: [original]))
        XCTAssertNotEqual(next.generation, guardState.generation)
        XCTAssertTrue(next.validate(groups: [original]))
        guardState.invalidate()
        XCTAssertTrue(next.validate(groups: [original]))
    }

    func testMembershipOverviewAndLossRevoke() throws {
        let group = UUID(), first = UUID(), second = UUID()
        let original = RegisteredTabSelection.Group(id: group, members: [first, second], selected: first, overviewVisible: false)
        for changed: [RegisteredTabSelection.Group] in [[], [.init(id: group, members: [first], selected: first, overviewVisible: false)], [.init(id: group, members: [first, second], selected: first, overviewVisible: true)], [original, original]] {
            let guardState = try XCTUnwrap(RegisteredTabSelection(groups: [original]))
            XCTAssertFalse(guardState.validate(groups: changed))
            XCTAssertFalse(guardState.validate(groups: [original]))
        }
    }
}
