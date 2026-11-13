#if SAFARIER_WHEEL_OBSERVER_PROBE
import Foundation

// These pins must be populated from a separately reviewed, pre-signed artifact
// before a probe build. Missing values fail closed; no values are read from it.
enum BoundWheelObserverArtifactPin {
    static let relativeBundle = "Contents/PlugIns/SafarierWheelObserver.bundle"
    static let identifier = "sh.safarier.boundcandidate.wheelobserver"
    static let executable = "SafarierWheelObserver"
    static let infoSHA256: String? = "431b24f94893c8693306f0ab2865e0824efd41f7faf7caca43963dfcff2c5ac5"
    static let executableSHA256: String? = "0919ecd276236c98a448e2c37150773040f452201e0c33d3c4cb052f854d7713"
    static let codeResourcesSHA256: String? = "6686de10a28a2fe11b36cbb86dcbacc827cfc4ea116b4dabf1845e5aee629e9b"
    static let cdHash: String? = "29d07339c8f3c267515012a3e06b3c8e2fa6846a"

    struct Pins {
        let info: String, executable: String, resources: String, cdHash: String
    }
    static func required() throws -> Pins {
        guard let infoSHA256, let executableSHA256, let codeResourcesSHA256, let cdHash,
              validHex(infoSHA256, bytes: 32), validHex(executableSHA256, bytes: 32),
              validHex(codeResourcesSHA256, bytes: 32),
              (validHex(cdHash, bytes: 20) || validHex(cdHash, bytes: 32)) else { throw IdentityBridgeError.rejected }
        return Pins(info: infoSHA256, executable: executableSHA256, resources: codeResourcesSHA256, cdHash: cdHash)
    }
    private static func validHex(_ s: String, bytes: Int) -> Bool {
        s.utf8.count == bytes * 2 && s.utf8.contains(where: { $0 != 48 }) &&
        s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func namespace(_ pins: Pins) -> [(String, Bool, String?)] { [
        ("Contents", true, nil), ("Contents/Info.plist", false, pins.info),
        ("Contents/MacOS", true, nil), ("Contents/MacOS/SafarierWheelObserver", false, pins.executable),
        ("Contents/_CodeSignature", true, nil), ("Contents/_CodeSignature/CodeResources", false, pins.resources)
    ] }
}
#endif
