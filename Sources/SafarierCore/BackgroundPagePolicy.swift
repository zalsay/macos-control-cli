import Foundation

public enum BrowserExecutionPolicy: Sendable {
    case interactive, automationBackground
}

public enum BackgroundUIRequest: String, CaseIterable, Sendable {
    case start
    case openWindow
    case openTab
    case reopen
    case cycleWindow
    case targetBlank
    case windowOpen
    case windowClose
    case alert
    case confirm
    case prompt
    case beforeUnload
    case fileSelection
    case directorySelection
    case save
    case printPage
    case share
    case download
    case camera
    case microphone
    case geolocation
    case notification
    case screenCapture
    case clipboardRead
    case elementFullscreen
    case videoFullscreen
    case pictureInPicture
    case pointerLock
    case selectPopup
    case datePopup
    case colorPopup
    case autocompletePopup
    case contextMenu
    case longPress
    case linkPreview
    case htmlDrag
    case systemDrag
    case httpAuthentication
    case clientCertificate
    case webAuthn
    case passkey
    case applePay
    case externalURL
    case audiblePlayback
    case notificationSound
    /// Preserve only the existing validated proxy-bound authentication path; this is not
    /// an unconditional credential or UI authorization. Webpage challenges are separate.
    case proxyBoundAuthentication
    case unknown
}

public enum BackgroundUIDecision: Equatable, Sendable {
    case preserveExistingBehavior
    case cancelAndSuspend(blockReason: String)
}

public struct BackgroundPagePolicy: Sendable {
    public let mode: BrowserExecutionPolicy
    public init(mode: BrowserExecutionPolicy) { self.mode = mode }
    public func decide(_ request: BackgroundUIRequest) -> BackgroundUIDecision {
        if mode == .interactive || request == .proxyBoundAuthentication {
            return .preserveExistingBehavior
        }
        return .cancelAndSuspend(blockReason: "INTERACTION_REQUIRED")
    }

    public func route<T>(_ request: BackgroundUIRequest, onBlocked: (BackgroundUIRequest) -> Void, perform: () -> T, deny: () -> T) -> T {
        switch decide(request) {
        case .preserveExistingBehavior: return perform()
        case .cancelAndSuspend: onBlocked(request); return deny()
        }
    }

    /// Nil means a WebKit-internal scheme, not an authorization to open external apps.
    public static func navigationRequest(for url: URL?) -> BackgroundUIRequest? {
        guard let scheme = url?.scheme?.lowercased(), !scheme.isEmpty else { return .unknown }
        switch scheme {
        case "http", "https", "about", "data", "blob": return nil
        default: return .externalURL
        }
    }

}

/// A catalogue, not a claim that any control is installed or verified.
public enum BackgroundSafetyControl: String, CaseIterable, Sendable {
    case start
    case openWindow
    case openTab
    case reopen
    case cycleWindow
    case targetBlank
    case windowOpen
    case windowClose
    case alert
    case confirm
    case prompt
    case beforeUnload
    case fileSelection
    case directorySelection
    case save
    case printPage
    case share
    case download
    case camera
    case microphone
    case geolocation
    case notification
    case screenCapture
    case clipboardRead
    case elementFullscreen
    case videoFullscreen
    case pictureInPicture
    case pointerLock
    case selectPopup
    case datePopup
    case colorPopup
    case autocompletePopup
    case contextMenu
    case longPress
    case linkPreview
    case htmlDrag
    case systemDrag
    case httpAuthentication
    case clientCertificate
    case webAuthn
    case passkey
    case applePay
    case externalURL
    case audiblePlayback
    case notificationSound
    case initialWindowOrderOut
    case windowCannotBecomeKey
    case windowCannotBecomeMain
    case physicalMousePassThrough
    case noSpaceSwitch
    case noForegroundOrdering
    case muteWebView
    case disableAudibleAutoplay
}

public struct BackgroundSafetyProof: Sendable {
    public let runtimeBuildIdentifier: String
    public let reference: String
    public init(runtimeBuildIdentifier: String, reference: String) {
        self.runtimeBuildIdentifier = runtimeBuildIdentifier
        self.reference = reference
    }
}

public struct BackgroundSafetyEvidence: Sendable {
    public enum Status: Sendable { case verified, unavailable, unverified, conflicting }
    /// Raw IDs permit unknown incoming catalogue entries to be rejected rather than discarded.
    public let controlID: String
    public let status: Status
    public let signature: BackgroundSafetyProof?
    public let readback: BackgroundSafetyProof?
    public let isolatedNegativeFixture: BackgroundSafetyProof?
    public init(controlID: String, status: Status, signature: BackgroundSafetyProof?, readback: BackgroundSafetyProof?, isolatedNegativeFixture: BackgroundSafetyProof?) {
        self.controlID = controlID
        self.status = status
        self.signature = signature
        self.readback = readback
        self.isolatedNegativeFixture = isolatedNegativeFixture
    }
}

public struct BackgroundSafetyCapabilities: Sendable {
    public let runtimeBuildIdentifier: String
    public let evidence: [BackgroundSafetyEvidence]
    public init(runtimeBuildIdentifier: String, evidence: [BackgroundSafetyEvidence]) {
        self.runtimeBuildIdentifier = runtimeBuildIdentifier
        self.evidence = evidence
    }
    public static let unverified = BackgroundSafetyCapabilities(runtimeBuildIdentifier: "", evidence: [])
    public var isComplete: Bool {
        guard !runtimeBuildIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let required = Set(BackgroundSafetyControl.allCases.map(\.rawValue))
        guard evidence.count == required.count, Set(evidence.map(\.controlID)) == required else { return false }
        func valid(_ proof: BackgroundSafetyProof?) -> Bool {
            guard let proof else { return false }
            return proof.runtimeBuildIdentifier == runtimeBuildIdentifier && !proof.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return evidence.allSatisfy { item in
            item.status == .verified && valid(item.signature) && valid(item.readback) && valid(item.isolatedNegativeFixture)
        }
    }
}
