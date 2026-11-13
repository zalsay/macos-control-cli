import Foundation
import SafarierCore

public enum BackgroundPagePolicyCases {
    struct Failure: Error { let message: String }
    public static func run() throws -> Int {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            count += 1; if !condition() { throw Failure(message: label) }
        }
        let expected: Set<String> = ["start", "openWindow", "openTab", "reopen", "cycleWindow", "targetBlank", "windowOpen", "windowClose", "alert", "confirm", "prompt", "beforeUnload", "fileSelection", "directorySelection", "save", "printPage", "share", "download", "camera", "microphone", "geolocation", "notification", "screenCapture", "clipboardRead", "elementFullscreen", "videoFullscreen", "pictureInPicture", "pointerLock", "selectPopup", "datePopup", "colorPopup", "autocompletePopup", "contextMenu", "longPress", "linkPreview", "htmlDrag", "systemDrag", "httpAuthentication", "clientCertificate", "webAuthn", "passkey", "applePay", "externalURL", "audiblePlayback", "notificationSound", "proxyBoundAuthentication", "unknown"]
        try check(Set(BackgroundUIRequest.allCases.map(\.rawValue)) == expected, "exact request catalogue")
        let extraControls: Set<String> = ["initialWindowOrderOut", "windowCannotBecomeKey", "windowCannotBecomeMain", "physicalMousePassThrough", "noSpaceSwitch", "noForegroundOrdering", "muteWebView", "disableAudibleAutoplay"]
        try check(Set(BackgroundSafetyControl.allCases.map(\.rawValue)) == expected.subtracting(["proxyBoundAuthentication", "unknown"]).union(extraControls), "exact control catalogue")
        let interactive = BackgroundPagePolicy(mode: .interactive)
        let background = BackgroundPagePolicy(mode: .automationBackground)
        for request in BackgroundUIRequest.allCases {
            try check(interactive.decide(request) == .preserveExistingBehavior, "interactive \(request)")
            if request == .proxyBoundAuthentication {
                try check(background.decide(request) == .preserveExistingBehavior, "proxy remains existing behavior")
            } else {
                try check(background.decide(request) == .cancelAndSuspend(blockReason: "INTERACTION_REQUIRED"), "fixed block reason \(request)")
            }
        }
        // A pure consumer demonstrates decision ordering; this does not simulate the factory or WebKit.
        var sideEffects = 0
        for request in BackgroundUIRequest.allCases where request != .proxyBoundAuthentication {
            if background.decide(request) == .preserveExistingBehavior { sideEffects += 1 }
        }
        try check(sideEffects == 0, "blocked decisions never invoke hypothetical operations")
        try check(!BackgroundSafetyCapabilities.unverified.isComplete, "unverified")
        let build = "synthetic-test-build"
        let proof = BackgroundSafetyProof(runtimeBuildIdentifier: build, reference: "synthetic-test-evidence")
        let entries = BackgroundSafetyControl.allCases.map { BackgroundSafetyEvidence(controlID: $0.rawValue, status: .verified, signature: proof, readback: proof, isolatedNegativeFixture: proof) }
        func complete(_ evidence: [BackgroundSafetyEvidence], _ runtime: String = build) -> Bool {
            BackgroundSafetyCapabilities(runtimeBuildIdentifier: runtime, evidence: evidence).isComplete
        }
        try check(complete(entries), "synthetic complete; not actual G2")
        try check(!complete(Array(entries.dropLast())), "missing control")
        for unknownID in ["unknown", "unsupportedControl"] {
            let unknown = BackgroundSafetyEvidence(controlID: unknownID, status: .verified, signature: proof, readback: proof, isolatedNegativeFixture: proof)
            try check(!complete(Array(entries.dropLast()) + [unknown]), "replacement unknown control \(unknownID)")
            try check(!complete(entries + [unknown]), "appended unknown control \(unknownID)")
        }
        try check(!complete(entries + [entries[0]]), "duplicate/conflicting evidence")
        try check(!complete(entries, "other-build"), "wrong runtime build")
        try check(!complete(entries, ""), "empty runtime build")
        for status in [BackgroundSafetyEvidence.Status.unavailable, .unverified, .conflicting] {
            var changed = entries
            changed[0] = BackgroundSafetyEvidence(controlID: entries[0].controlID, status: status, signature: proof, readback: proof, isolatedNegativeFixture: proof)
            try check(!complete(changed), "status \(status)")
        }
        for field in 0..<3 {
            var changed = entries
            changed[0] = BackgroundSafetyEvidence(controlID: entries[0].controlID, status: .verified, signature: field == 0 ? nil : proof, readback: field == 1 ? nil : proof, isolatedNegativeFixture: field == 2 ? nil : proof)
            try check(!complete(changed), "missing proof \(field)")
            let wrong = BackgroundSafetyProof(runtimeBuildIdentifier: "wrong", reference: "synthetic")
            changed[0] = BackgroundSafetyEvidence(controlID: entries[0].controlID, status: .verified, signature: field == 0 ? wrong : proof, readback: field == 1 ? wrong : proof, isolatedNegativeFixture: field == 2 ? wrong : proof)
            try check(!complete(changed), "wrong proof build \(field)")
        }
        var changed = entries
        changed[0] = BackgroundSafetyEvidence(controlID: entries[0].controlID, status: .verified, signature: .init(runtimeBuildIdentifier: build, reference: "  "), readback: proof, isolatedNegativeFixture: proof)
        try check(!complete(changed), "blank evidence")
        return count
    }
}
