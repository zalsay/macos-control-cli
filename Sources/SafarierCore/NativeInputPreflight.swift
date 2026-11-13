import Foundation

public enum NativeInputPreflight {
    public enum ButtonAction { case down, up, click, move }
    /// G0, G1 and G2 are not verified; no caller can supply an override.
    public static var shippingAdmissionAvailable: Bool { false }
    public static func nextButtonState(held: Bool, action: ButtonAction) -> Bool? {
        switch (held, action) {
        case (false, .down): return true
        case (true, .up): return false
        case (false, .click): return false
        case (_, .move): return held
        default: return nil
        }
    }
    public static func viewportValid(_ v: AutomationViewport) -> Bool {
        v.viewportWidthPoints.isFinite && v.viewportWidthPoints > 0 && v.viewportHeightPoints.isFinite && v.viewportHeightPoints > 0 && v.pixelWidth > 0 && v.pixelHeight > 0 && v.scaleX.isFinite && v.scaleX > 0 && v.scaleY.isFinite && v.scaleY > 0 && v.pageZoom.isFinite && v.pageZoom > 0
    }
    public static func geometryMatches(_ viewport: AutomationViewport, width: Double, height: Double, scale: Double, zoom: Double, version: UInt64) -> Bool {
        guard viewportValid(viewport), width.isFinite, height.isFinite, scale.isFinite, scale > 0, zoom.isFinite, zoom > 0 else { return false }
        return viewport.viewVersion == version && viewport.viewportWidthPoints == width && viewport.viewportHeightPoints == height && viewport.pageZoom == zoom && Double(viewport.pixelWidth) == (width * scale).rounded() && Double(viewport.pixelHeight) == (height * scale).rounded() && viewport.scaleX == Double(viewport.pixelWidth) / width && viewport.scaleY == Double(viewport.pixelHeight) / height
    }
    public static func requiresOwnedTargetDestruction(held: Bool, pending: Bool, uncertain: Bool, previouslyRequired: Bool) -> Bool {
        held || pending || uncertain || previouslyRequired
    }
    public static func keyAllowed(name: AutomationKey, shift: Bool) -> Bool {
        guard shift else { return true }
        switch name {
        case .tab, .left, .right, .up, .down, .home, .end: return true
        case .backspace, .delete, .enter, .escape: return false
        }
    }
    public static func textAllowed(_ text: String) -> Bool { text.utf8.count <= AutomationLimits.textBytes }
    public static func scrollDelta(x: Double, y: Double) -> Int32? {
        guard x.isFinite, y.isFinite, abs(x) <= 1000, abs(y) <= 1000, x == 0, y.rounded(.towardZero) == y else { return nil }
        return Int32(y)
    }
    public final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        public init() {}
        public func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
