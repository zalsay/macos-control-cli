import Foundation
import Darwin
@main struct ArtifactBaseMain {
    static func main() { do { let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ARTIFACT_BASE_FIXTURE"]!); print("PASS: \(try ArtifactBaseCases.run(root: base)) artifact base checks") } catch { print("FAIL: \(error)"); exit(1) } }
}
