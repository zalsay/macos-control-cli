import AppKit

struct ManagerWindowSize {
    static let key = "ManagerWindowFrameSize"
    static let minimum = NSSize(width: 920, height: 580)
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private static func valid(_ size: NSSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    func load() -> NSSize? {
        guard let value = defaults.dictionary(forKey: Self.key),
              let width = value["width"] as? NSNumber, CFGetTypeID(width) != CFBooleanGetTypeID(),
              let height = value["height"] as? NSNumber, CFGetTypeID(height) != CFBooleanGetTypeID() else { return nil }
        let size = NSSize(width: width.doubleValue, height: height.doubleValue)
        return Self.valid(size) ? size : nil
    }

    func save(_ size: NSSize) {
        guard Self.valid(size) else { return }
        defaults.set(["width": Double(size.width), "height": Double(size.height)], forKey: Self.key)
    }

    static func resolve(_ saved: NSSize?, screen: NSSize?) -> NSSize {
        let preferred = NSSize(width: 1600, height: 1200)
        let fallback = NSSize(width: 1280, height: 800)
        let available = screen.flatMap { valid($0) ? $0 : nil }
        let initial = available.map { $0.width >= preferred.width && $0.height >= preferred.height ? preferred : fallback } ?? fallback
        let desired = saved.flatMap { valid($0) ? $0 : nil } ?? initial
        let width = max(minimum.width, min(desired.width, available?.width ?? desired.width))
        let height = max(minimum.height, min(desired.height, available?.height ?? desired.height))
        return NSSize(width: width, height: height)
    }
}

struct ManagerNormalWindowSize {
    private(set) var size: NSSize
    var changingFullScreen = false

    mutating func observe(_ frameSize: NSSize, fullScreen: Bool, miniaturized: Bool) {
        guard !changingFullScreen, !fullScreen, !miniaturized,
              frameSize.width.isFinite, frameSize.height.isFinite,
              frameSize.width > 0, frameSize.height > 0 else { return }
        size = frameSize
    }
}
