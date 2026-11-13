import SafarierCore

/// Candidate fixture action classification only; this is not identity authority.
/// Existing pointer actions are left to the original bound-page checks.
enum BoundFixtureFormPolicy {
    enum FormOperation: Equatable {
        case clickButton, clickText, insertASCII, backspace, left, right, insertChinese
    }

    static func validate(_ action: AutomationAction, held: Bool) throws -> FormOperation? {
        switch action {
        case .move, .mouseDown, .mouseUp:
            return nil
        case let .click(point, _, count) where !held && count == 1:
            if point.x >= 40 && point.x < 180 && point.y >= 40 && point.y < 100 { return .clickButton }
            if point.x >= 40 && point.x < 360 && point.y >= 140 && point.y < 180 { return .clickText }
        case .insertText("native-123") where !held:
            return .insertASCII
        case .insertText("中文") where !held:
            return .insertChinese
        case .key(name: .backspace, shift: false) where !held:
            return .backspace
        case .key(name: .left, shift: false) where !held:
            return .left
        case .key(name: .right, shift: false) where !held:
            return .right
        default:
            break
        }
        throw AutomationError(code: .uiPolicyUnavailable)
    }
}
