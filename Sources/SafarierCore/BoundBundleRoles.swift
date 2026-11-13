import Foundation

// Pure fixed path mapping; it does not establish identity or authorize a process.
enum BoundBundleRole { case main, runner }

struct BoundBundleRoles {
    #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
    static let mainExecutableLeaf = "Safarier AI"
    static let runnerExecutableLeaf = "Safarier AI Browser"
    #else
    static let mainExecutableLeaf = "Safarier"
    static let runnerExecutableLeaf = "SafarierRunner"
    #endif
    static let runnerBundleRelative = "Contents/Helpers/" + runnerExecutableLeaf + ".app"
    static let mainExecutableRelative = "Contents/MacOS/" + mainExecutableLeaf
    static let runnerExecutableRelative = runnerBundleRelative + "/Contents/MacOS/" + runnerExecutableLeaf

    let role: BoundBundleRole
    let outerRoot: String
    let runnerRoot: String
    let mainExecutablePath: String
    let runnerExecutablePath: String

    init(selfExecutablePath: String) throws {
        let components = selfExecutablePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first == "", !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw IdentityBridgeError.rejected
        }
        let mainSuffix = "/" + Self.mainExecutableRelative
        let runnerSuffix = "/" + Self.runnerExecutableRelative
        let suffix: String
        if selfExecutablePath.hasSuffix(runnerSuffix) {
            role = .runner; suffix = runnerSuffix
        } else if selfExecutablePath.hasSuffix(mainSuffix) {
            role = .main; suffix = mainSuffix
        } else { throw IdentityBridgeError.rejected }
        let root = String(selfExecutablePath.dropLast(suffix.count))
        guard root.hasPrefix("/"), root.hasSuffix(".app"),
              (root as NSString).lastPathComponent.count > 4 else { throw IdentityBridgeError.rejected }
        outerRoot = root
        runnerRoot = root + "/" + Self.runnerBundleRelative
        mainExecutablePath = root + "/" + Self.mainExecutableRelative
        runnerExecutablePath = root + "/" + Self.runnerExecutableRelative
    }
}
