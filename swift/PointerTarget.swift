import Foundation
import CoreGraphics
import Darwin

private func requirePointerTarget(_ actual: TargetWindow, expected: TargetWindow) throws {
    guard actual.windowId > 0, actual.pid > 0 else { throw pointerUnverified() }
    guard actual.windowId == expected.windowId, actual.pid == expected.pid else {
        throw HelperFailure(code: "POINTER_OBSCURED", message: "鼠标目标点的实际输入接收窗口不是指定 Chrome，已阻止后续输入")
    }
}

func pointerUnverified() -> HelperFailure {
    HelperFailure(code: "POINTER_UNVERIFIED", message: "无法确认鼠标目标点的实际输入接收窗口，已阻止后续输入")
}

func verifyPointerOwnership(target: TargetWindow, eventTarget: () throws -> TargetWindow,
                            accessibilityTarget: () throws -> TargetWindow) throws {
    try requirePointerTarget(eventTarget(), expected: target)
    try requirePointerTarget(accessibilityTarget(), expected: target)
    // AX 查询可能耗时；结束后再次核实，避免把检查中途新增的输入遮挡放行。
    try requirePointerTarget(eventTarget(), expected: target)
}

func conservativePointerTarget(at point: CGPoint, windows: [[String: Any]]) throws -> TargetWindow {
    for info in windows {
        guard let raw = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: raw as CFDictionary), rect.contains(point),
              (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
        // 已确认覆盖点的前景窗口身份未知时必须关闭，不能继续接受下层 Chrome。
        guard let windowId = info[kCGWindowNumber as String] as? UInt32, windowId > 0,
              let pid = info[kCGWindowOwnerPID as String] as? Int32, pid > 0 else { throw pointerUnverified() }
        return TargetWindow(windowId: windowId, pid: pid)
    }
    throw pointerUnverified()
}

// CGWindowList 的绘制顺序不代表输入归属；只读取 WindowServer 实际命中，不投递事件。
// SPI 动态探测：符号缺失时由调用方保守检查；查询失败时拒绝输入，不能只相信 AX。
final class WindowEventHitReader {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Find = @convention(c) (Int32, Int32, Int32, Int32,
        UnsafeMutablePointer<CGPoint>, UnsafeMutablePointer<CGPoint>,
        UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<Int32>) -> Int32
    private typealias OwnerPID = @convention(c) (Int32, UnsafeMutablePointer<pid_t>) -> Int32
    private let library: UnsafeMutableRawPointer?
    private let connection: Connection?
    private let find: Find?
    private let ownerPID: OwnerPID?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        library = handle
        connection = handle.flatMap { dlsym($0, "SLSMainConnectionID") }.map { unsafeBitCast($0, to: Connection.self) }
        find = handle.flatMap { dlsym($0, "SLSFindWindowAndOwner") }.map { unsafeBitCast($0, to: Find.self) }
        ownerPID = handle.flatMap { dlsym($0, "SLSConnectionGetPID") }.map { unsafeBitCast($0, to: OwnerPID.self) }
    }

    deinit { if let library { dlclose(library) } }

    var isAvailable: Bool { connection != nil && find != nil && ownerPID != nil }

    func target(at point: CGPoint) throws -> TargetWindow {
        guard let connection, let find, let ownerPID else { throw pointerUnverified() }
        let cid = connection()
        var screenPoint = point, localPoint = CGPoint.zero
        var windowID: UInt32 = 0
        var ownerConnection: Int32 = 0
        guard cid > 0,
              find(cid, 0, 1, 0, &screenPoint, &localPoint, &windowID, &ownerConnection) == 0,
              windowID > 0, ownerConnection > 0 else { throw pointerUnverified() }
        var pid: pid_t = 0
        guard ownerPID(ownerConnection, &pid) == 0, pid > 0 else { throw pointerUnverified() }
        return TargetWindow(windowId: windowID, pid: pid)
    }
}
