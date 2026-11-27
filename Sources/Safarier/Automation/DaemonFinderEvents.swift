import AppKit
import Darwin
import SafarierCore

/// LaunchServices can address a Finder reopen to the surviving daemon because
/// Manager and daemon execute the same bundle. Only relay that UI event.
@MainActor
final class DaemonFinderEvents: NSObject, NSApplicationDelegate {
    private var stopping = false
    private var launching = false
    private var launchTarget: NSRunningApplication?

    static func isManagerCandidate(_ app: NSRunningApplication) -> Bool {
        guard app.isFinishedLaunching, !app.isTerminated,
              let argv = arguments(of: app.processIdentifier) else { return false }
        return ExecutableRole.resolve(argv) == .manager
    }

    static func isServingDaemon(_ app: NSRunningApplication) -> Bool {
        arguments(of: app.processIdentifier)?.starts(with: ["control", "daemon", "serve"]) == true
    }

    // LaunchServices can transiently promote the daemon when Finder targets it.
    // Use argv only for role selection; the control path still verifies the
    // retained process identity and the signed executable before sending.
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 4 * 1024 * 1024 else { return nil }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = data.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0, argc <= 4096, let end = data[4..<size].firstIndex(of: 0) else { return nil }
        var i = end
        while i < size && data[i] == 0 { i += 1 }
        var result = [String]()
        for index in 0..<argc {
            guard i < size, let next = data[i..<size].firstIndex(of: 0) else { return nil }
            if index > 0 { result.append(String(decoding: data[i..<next], as: UTF8.self)) }
            i = next + 1
        }
        return result
    }

    func prepare() throws {
        let app = NSApplication.shared
        guard app.setActivationPolicy(.prohibited) else { throw ControlRuntime.Failure.unsafe }
        app.delegate = self
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(reopen(_:reply:)),
            forEventClass: 0x61657674, andEventID: 0x72617070)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateCancel // Shutdown goes through the broker's idle check.
    }

    @objc private func reopen(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        let bundle = Bundle.main
        guard let id = bundle.bundleIdentifier, !launching else { return }
        let managers = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != getpid() && Self.isManagerCandidate($0) &&
                $0.bundleURL?.resolvingSymlinksInPath() == bundle.bundleURL.resolvingSymlinksInPath() }
        if let manager = managers.first {
            guard managers.count == 1 else { return }
            let target = NSAppleEventDescriptor(processIdentifier: manager.processIdentifier)
            let reopen = NSAppleEventDescriptor(eventClass: 0x61657674, eventID: 0x72617070,
                targetDescriptor: target, returnID: -1, transactionID: 0)
            _ = try? reopen.sendEvent(options: [.noReply, .neverInteract], timeout: 1)
            return
        }
        if let launchTarget, !launchTarget.isTerminated { return }
        launching = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundle.bundleURL, configuration: configuration) { app, _ in
            Task { @MainActor in self.launchTarget = app; self.launching = false }
        }
    }

    func run() {
        let app = NSApplication.shared
        while !stopping {
            autoreleasepool {
                if let event = app.nextEvent(matching: .any, until: .distantFuture, inMode: .default, dequeue: true) {
                    app.sendEvent(event)
                }
            }
        }
    }

    func stop() {
        stopping = true
        if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApplication.shared.postEvent(wake, atStart: true)
        }
    }
}
