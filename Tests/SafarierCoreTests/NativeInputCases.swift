import Foundation
import SafarierCore
public enum NativeInputCases {
    struct Failure: Error { let label: String }
    public static func run() throws -> Int {
        var n = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws { n += 1; if !value() { throw Failure(label: label) } }
        let v = AutomationViewport(viewportWidthPoints: 1280, viewportHeightPoints: 800, pixelWidth: 2560, pixelHeight: 1600, scaleX: 2, scaleY: 2, pageZoom: 1, viewVersion: 1)
        for p in [ViewportPoint(x: 0, y: 0), ViewportPoint(x: 1279, y: 799)] { try check(v.contains(p), "inside") }
        for p in [ViewportPoint(x: 1280, y: 1), ViewportPoint(x: 0, y: 800), ViewportPoint(x: -1, y: 0), ViewportPoint(x: .infinity, y: 0), ViewportPoint(x: .nan, y: 1)] { try check(!v.contains(p), "outside") }
        try check(!NativeInputPreflight.shippingAdmissionAvailable, "shipping always denied")
        try check(NativeInputPreflight.nextButtonState(held: false, action: .down) == true, "down")
        try check(NativeInputPreflight.nextButtonState(held: true, action: .up) == false, "up")
        try check(NativeInputPreflight.nextButtonState(held: false, action: .up) == nil, "up idle")
        try check(NativeInputPreflight.nextButtonState(held: true, action: .down) == nil, "down held")
        try check(NativeInputPreflight.nextButtonState(held: true, action: .click) == nil, "click held")
        try check(NativeInputPreflight.nextButtonState(held: false, action: .click) == false, "click idle")
        try check(NativeInputPreflight.viewportValid(v), "valid geometry")
        try check(NativeInputPreflight.geometryMatches(v, width: 1280, height: 800, scale: 2, zoom: 1, version: 1), "matching pinned geometry")
        try check(!NativeInputPreflight.geometryMatches(v, width: 1281, height: 800, scale: 2, zoom: 1, version: 1), "changed bounds")
        try check(!NativeInputPreflight.geometryMatches(v, width: 1280, height: 800, scale: 3, zoom: 1, version: 1), "changed scale")
        try check(!NativeInputPreflight.geometryMatches(v, width: 1280, height: 800, scale: 2, zoom: 2, version: 1), "changed zoom")
        try check(!NativeInputPreflight.geometryMatches(v, width: 1280, height: 800, scale: 2, zoom: 1, version: 2), "changed version")
        try check(!NativeInputPreflight.geometryMatches(v, width: .infinity, height: 800, scale: 2, zoom: 1, version: 1), "nonfinite geometry")
        let bad = AutomationViewport(viewportWidthPoints: 1, viewportHeightPoints: 1, pixelWidth: 2, pixelHeight: 2, scaleX: .nan, scaleY: 2, pageZoom: 1, viewVersion: 1)
        try check(!NativeInputPreflight.viewportValid(bad), "invalid geometry")
        try check(NativeInputPreflight.requiresOwnedTargetDestruction(held: true, pending: false, uncertain: false, previouslyRequired: false), "held cleanup")
        try check(NativeInputPreflight.requiresOwnedTargetDestruction(held: false, pending: true, uncertain: false, previouslyRequired: false), "pending cleanup")
        try check(NativeInputPreflight.requiresOwnedTargetDestruction(held: false, pending: false, uncertain: true, previouslyRequired: false), "uncertain cleanup")
        try check(NativeInputPreflight.requiresOwnedTargetDestruction(held: false, pending: false, uncertain: false, previouslyRequired: true), "sticky cleanup")
        try check(!NativeInputPreflight.requiresOwnedTargetDestruction(held: false, pending: false, uncertain: false, previouslyRequired: false), "idle cleanup")
        try check(NativeInputPreflight.textAllowed(String(repeating: "a", count: 16384)), "text limit")
        try check(!NativeInputPreflight.textAllowed(String(repeating: "a", count: 16385)), "text overflow")
        try check(!NativeInputPreflight.textAllowed(String(repeating: "中", count: 5462)), "UTF8 byte limit")
        try check(NativeInputPreflight.scrollDelta(x: 0, y: -1000) == -1000, "bounded scroll")
        try check(NativeInputPreflight.scrollDelta(x: 1, y: 2) == nil, "horizontal refused")
        try check(NativeInputPreflight.scrollDelta(x: 0, y: 0.5) == nil, "fractional refused")
        try check(NativeInputPreflight.scrollDelta(x: 0, y: 1001) == nil, "scroll limit")
        try check(NativeInputPreflight.scrollDelta(x: 0, y: .nan) == nil, "nonfinite scroll")
        let keys: [AutomationKey] = [.backspace, .delete, .enter, .tab, .escape, .left, .right, .up, .down, .home, .end]
        let shiftKeys: Set<AutomationKey> = [.tab, .left, .right, .up, .down, .home, .end]
        for key in keys {
            try check(NativeInputPreflight.keyAllowed(name: key, shift: false), "unshifted key")
            try check(NativeInputPreflight.keyAllowed(name: key, shift: true) == shiftKeys.contains(key), "shifted key")
        }
        let gate = NativeInputPreflight.OneShot()
        try check(gate.claim(), "first completion wins")
        try check(!gate.claim(), "duplicate completion ignored")
        let concurrentGate = NativeInputPreflight.OneShot()
        let lock = NSLock()
        var winners = 0
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            if concurrentGate.claim() { lock.lock(); winners += 1; lock.unlock() }
        }
        try check(winners == 1, "one winner under concurrent completions")
        return n
    }
}
