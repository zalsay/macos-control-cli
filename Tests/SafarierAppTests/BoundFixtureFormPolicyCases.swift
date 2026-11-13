import Foundation
import SafarierCore
#if !MANAGER_STANDALONE
import XCTest
@testable import Safarier
#endif

// Pure action classification only: no Binder, page, native input, or identity proof.
public enum BoundFixtureFormPolicyCases {
    struct Failure: Error { let label: String }
    private static let button = ViewportPoint(x: 100, y: 70)
    private static let text = ViewportPoint(x: 100, y: 160)
    private static func click(_ point: ViewportPoint, count: Int = 1) -> AutomationAction {
        .click(point: point, viewVersion: 1, count: count)
    }
    private static func mustAllow(_ action: AutomationAction, _ expected: BoundFixtureFormPolicy.FormOperation, _ label: String) throws {
        do {
            guard try BoundFixtureFormPolicy.validate(action, held: false) == expected else { throw Failure(label: label) }
        } catch is Failure { throw Failure(label: label) }
        catch { throw Failure(label: label) }
    }
    private static func mustDeny(_ action: AutomationAction, held: Bool = false, _ label: String) throws {
        do { _ = try BoundFixtureFormPolicy.validate(action, held: held) }
        catch let error as AutomationError where error.code == .uiPolicyUnavailable { return }
        catch { throw Failure(label: label + ".wrong_error") }
        throw Failure(label: label + ".unexpected_allow")
    }
    public static func run(_ label: String) throws {
        switch label {
        case "button":
            try mustAllow(click(button), .clickButton, label)
        case "text_click":
            try mustAllow(click(text), .clickText, label)
        case "fixed_text":
            try mustAllow(.insertText("native-123"), .insertASCII, label + ".ascii")
            try mustAllow(.insertText("中文"), .insertChinese, label + ".chinese")
        case "keys":
            try mustAllow(.key(name: .backspace, shift: false), .backspace, label + ".backspace")
            try mustAllow(.key(name: .left, shift: false), .left, label + ".left")
            try mustAllow(.key(name: .right, shift: false), .right, label + ".right")
        case "held":
            try mustDeny(click(button), held: true, label + ".click")
            try mustDeny(.insertText("native-123"), held: true, label + ".text")
            try mustDeny(.key(name: .backspace, shift: false), held: true, label + ".key")
        case "targets":
            try mustDeny(click(ViewportPoint(x: 500, y: 115)), label + ".password")
            try mustDeny(click(ViewportPoint(x: 500, y: 170)), label + ".selection")
            try mustDeny(click(ViewportPoint(x: 220, y: 400)), label + ".scroll_target")
        case "deny_actions":
            try mustDeny(.key(name: .tab, shift: false), label + ".tab")
            try mustDeny(.key(name: .enter, shift: false), label + ".enter")
            try mustDeny(.key(name: .left, shift: true), label + ".shift")
            try mustDeny(.insertText("unapproved"), label + ".arbitrary_text")
            try mustDeny(.scroll(point: ViewportPoint(x: 220, y: 400), viewVersion: 1, deltaX: 0, deltaY: 1), label + ".wheel")
        case "click_and_pointer":
            try mustDeny(click(button, count: 2), label + ".double_button")
            try mustDeny(click(text, count: 2), label + ".double_text")
            guard try BoundFixtureFormPolicy.validate(.move(point: button, viewVersion: 1), held: false) == nil else { throw Failure(label: label + ".pointer_delegation") }
        default: throw Failure(label: "unknown_case")
        }
    }
}
#if !MANAGER_STANDALONE
final class BoundFixtureFormPolicyTests: XCTestCase {
    func testCases() throws {
        for label in ["button", "text_click", "fixed_text", "keys", "held", "targets", "deny_actions", "click_and_pointer"] {
            try BoundFixtureFormPolicyCases.run(label)
        }
    }
}
#endif
