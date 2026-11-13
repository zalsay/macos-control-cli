import Foundation
import Darwin
import BinderIdentity
import BundleInventory

// These contracts are reviewed local constants, never values received over IPC,
// argv, environment, or a manifest discovered from the target itself.
enum OfflineBundleContract {
    case localCandidate, localCandidateRunner
    var bid: String {
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        return self == .localCandidate ? "sh.safarier.testing" : "sh.safarier.testing.runner"
        #else
        return self == .localCandidate ? "sh.safarier.boundcandidate" : "sh.safarier.boundcandidate.runner"
        #endif
    }
    var leaf: String { self == .localCandidate ? BoundBundleRoles.mainExecutableLeaf : BoundBundleRoles.runnerExecutableLeaf }
    private static let fixtureHash = "45f599bd8d943192d3f93045559a825b8922f5b2df8106393fc896394355edc1"
    private static func runnerNamespace() throws -> [(String, Bool, String?)] {
        var entries: [(String, Bool, String?)] = [
            ("Contents",true,nil), ("Contents/Info.plist",false,nil),
            ("Contents/MacOS",true,nil), ("Contents/MacOS/" + BoundBundleRoles.runnerExecutableLeaf,false,nil),
            ("Contents/Resources",true,nil), ("Contents/Resources/control-fixture.html",false,fixtureHash),
            ("Contents/_CodeSignature",true,nil), ("Contents/_CodeSignature/CodeResources",false,nil)
        ]
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        entries.append(("Contents/Resources/AppIcon.icns",false,"ae937f29c597080775e53a52c8337aa5e0dc1d268a8b26ad25ec193c2e7d374c"))
        #endif
        #if SAFARIER_WHEEL_OBSERVER_PROBE
        let pins = try BoundWheelObserverArtifactPin.required()
        let bundle = BoundWheelObserverArtifactPin.relativeBundle
        entries += [("Contents/PlugIns",true,nil), (bundle,true,nil)]
        entries += BoundWheelObserverArtifactPin.namespace(pins).map { (bundle + "/" + $0.0, $0.1, $0.2) }
        #endif
        return entries
    }
    fileprivate func namespace() throws -> [(String, Bool, String?)] {
        let runner = try Self.runnerNamespace()
        if self == .localCandidateRunner { return runner }
        var base: [(String, Bool, String?)] = [
            ("Contents",true,nil), ("Contents/Info.plist",false,nil),
            ("Contents/MacOS",true,nil), (BoundBundleRoles.mainExecutableRelative,false,nil),
            ("Contents/Resources",true,nil),
            ("Contents/Resources/Safarier.sdef",false,"0cb1c89e68376982342c0a4821b8f9a719d99e4ceb5b476e5ec748e773b5890c"),
            ("Contents/Resources/control-fixture.html",false,Self.fixtureHash),
            ("Contents/_CodeSignature",true,nil), ("Contents/_CodeSignature/CodeResources",false,nil),
            ("Contents/Helpers",true,nil), (BoundBundleRoles.runnerBundleRelative,true,nil)
        ]
        #if SAFARIER_INTERNAL_TEST_APP && SAFARIER_BOUND_LOCAL_CANDIDATE
        base.append(("Contents/Resources/AppIcon.icns",false,"ae937f29c597080775e53a52c8337aa5e0dc1d268a8b26ad25ec193c2e7d374c"))
        // Clash 订阅节点的内核（mihomo），和 scripts/bound-control-candidate/build.py 的 MIHOMO_REL / EXPECTED['mihomo'] 一致。
        base.append(("Contents/Helpers/mihomo",false,"3ebf3ac4c7f63764cd9e6174cd024b100236eb4c9252e2541f4416cb109ceda5"))
        #endif
        return base + runner.map { (BoundBundleRoles.runnerBundleRelative + "/" + $0.0, $0.1, $0.2) }
    }
}

// This object cannot be created from an inventory alone. Its only constructor is
// private; capture requires the independent full namespace and strict revalidate.
// Dynamic-process membership is separately checked by KernelIdentityBridge.
final class BundleResourcePin {
    private let handle: OpaquePointer
    private let contract: OfflineBundleContract
    private init(handle: OpaquePointer, contract: OfflineBundleContract) { self.handle=handle; self.contract=contract }
    deinit { bb_free(handle) }

    private static func checked(_ deadline: FrameDeadline, _ operation: (UInt64) -> BBError) throws {
        try Task.checkCancellation()
        let ms = min(2999, Int((try deadline.remaining() * 1000).rounded(.down)))
        guard ms > 0 else { throw HarnessError.deadline }
        let cDeadline = bi_deadline_after_ms(UInt32(ms))
        guard cDeadline != 0 else { throw HarnessError.deadline }
        let result = operation(cDeadline)
        _ = try deadline.remaining(); try Task.checkCancellation()
        guard result == BB_OK else { throw IdentityBridgeError.collector("bundle", Int32(result.rawValue)) }
    }

    private static func hex(_ text: String) throws -> [UInt8] {
        let bytes = Array(text.utf8)
        guard bytes.count == 64 else { throw IdentityBridgeError.rejected }
        func digit(_ c: UInt8) throws -> UInt8 {
            if c >= 48 && c <= 57 { return c - 48 }
            if c >= 97 && c <= 102 { return c - 87 }
            throw IdentityBridgeError.rejected
        }
        return try stride(from: 0, to: 64, by: 2).map { try digit(bytes[$0]) * 16 + digit(bytes[$0+1]) }
    }

    private static func expectExact(_ handle: OpaquePointer, namespace: [(String, Bool, String?)], deadline: FrameDeadline) throws {
        var names: [UnsafeMutablePointer<CChar>] = []
        var hashes: [UnsafeMutablePointer<UInt8>] = []
        defer { names.forEach { free($0) }; hashes.forEach { $0.deallocate() } }
        var expected: [BBExpected] = []
        for (path, directory, sha) in namespace {
            guard let name = strdup(path) else { throw IdentityBridgeError.rejected }
            names.append(name)
            var entry = BBExpected()
            entry.path = UnsafePointer(name); entry.is_directory = directory ? 1 : 0
            if let sha {
                let value = try hex(sha), digest = UnsafeMutablePointer<UInt8>.allocate(capacity: 32)
                value.withUnsafeBufferPointer { digest.initialize(from: $0.baseAddress!, count: $0.count) }; hashes.append(digest); entry.sha256 = UnsafePointer(digest)
            }
            expected.append(entry)
        }
        // exact membership is checked before revalidate; revalidate performs
        // complete inventory before and after strict bundle signature/main pin.
        try checked(deadline) { _ in expected.withUnsafeBufferPointer { bb_expect_exact(handle, $0.baseAddress, $0.count) } }
    }
    static func capture(root: String, contract: OfflineBundleContract, deadline: FrameDeadline) throws -> BundleResourcePin {
        var observed: OpaquePointer?
        // checked may throw on a late successful C return or cancellation;
        // own any returned inventory before entering that call.
        defer { if let observed { bb_free(observed) } }
        try checked(deadline) { d in
            let result = root.withCString { bb_inventory($0, d, &observed) }
            return result
        }
        guard let handle = observed else { throw IdentityBridgeError.rejected }
        try expectExact(handle, namespace: contract.namespace(), deadline: deadline)
        try checked(deadline) { d in contract.bid.withCString { bid in contract.leaf.withCString { leaf in bb_revalidate(handle, bid, leaf, d) } } }
        #if SAFARIER_WHEEL_OBSERVER_PROBE
        if contract == .localCandidate {
            let pluginRoot = root + "/" + BoundBundleRoles.runnerBundleRelative + "/" + BoundWheelObserverArtifactPin.relativeBundle
            try verifyObserver(root: pluginRoot, deadline: deadline)
            // The original fixed parent inventory brackets the child signature check.
            try checked(deadline) { d in contract.bid.withCString { bid in contract.leaf.withCString { leaf in bb_revalidate(handle, bid, leaf, d) } } }
        }
        #endif
        observed = nil // ownership transfers only after all checks succeed
        return BundleResourcePin(handle: handle, contract: contract)
    }
    #if SAFARIER_WHEEL_OBSERVER_PROBE
    private static func verifyObserver(root: String, deadline: FrameDeadline) throws {
        let pins = try BoundWheelObserverArtifactPin.required()
        var observed: OpaquePointer?
        defer { if let observed { bb_free(observed) } }
        try checked(deadline) { d in root.withCString { bb_inventory($0, d, &observed) } }
        guard let handle = observed else { throw IdentityBridgeError.rejected }
        try expectExact(handle, namespace: BoundWheelObserverArtifactPin.namespace(pins), deadline: deadline)
        var code = BBCodeIdentity()
        try checked(deadline) { d in
            root.withCString { path in BoundWheelObserverArtifactPin.identifier.withCString { bid in
                bb_validate_signature(path, bid, d, &code)
            } }
        }
        let count = Int(code.code_hash_len)
        guard count == 20 || count == 32 else { throw IdentityBridgeError.rejected }
        let actual = withUnsafeBytes(of: &code.code_hash) { $0.prefix(count).map { String(format: "%02x", $0) }.joined() }
        guard actual == pins.cdHash else { throw IdentityBridgeError.rejected }
    }
    #endif
    func revalidate(deadline: FrameDeadline) throws {
        try Self.checked(deadline) { d in contract.bid.withCString { bid in contract.leaf.withCString { leaf in bb_revalidate(handle, bid, leaf, d) } } }
    }
}
