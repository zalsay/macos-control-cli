import Foundation
import CoreGraphics

struct CursorMotionSample {
    let point: CGPoint
    let time: TimeInterval
}

struct CursorMotion {
    let samples: [CursorMotionSample]
    var duration: TimeInterval { samples.last?.time ?? 0 }
}

private func cursorMotionFailure() -> HelperFailure {
    HelperFailure(code: "INPUT_FAILED", message: "无法生成可用屏幕内的鼠标轨迹，未执行点击")
}

// CGDisplayBounds与CGEvent使用同一个屏幕坐标系，不使用NSEvent的左下原点坐标。
func cursorDisplayBounds() throws -> [CGRect] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0, count <= 128 else {
        throw cursorMotionFailure()
    }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    let status = ids.withUnsafeMutableBufferPointer { CGGetActiveDisplayList(count, $0.baseAddress, &count) }
    guard status == .success, count > 0, Int(count) <= ids.count else { throw cursorMotionFailure() }
    return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
}

// 判定一段移动是否完全被屏幕并集覆盖，不能只检查两端就跨过多屏之间的空洞。
private func cursorSegmentIsVisible(_ start: CGPoint, _ end: CGPoint, displays: [CGRect]) -> Bool {
    var intervals: [(Double, Double)] = []
    for screen in displays {
        var lower = 0.0, upper = 1.0
        for (origin, delta, minimum, maximum) in [
            (start.x, end.x - start.x, screen.minX, screen.maxX),
            (start.y, end.y - start.y, screen.minY, screen.maxY)
        ] {
            if delta == 0 {
                if origin < minimum || origin > maximum { lower = 2; break }
            } else {
                let a = (minimum - origin) / delta, b = (maximum - origin) / delta
                lower = max(lower, min(a, b)); upper = min(upper, max(a, b))
            }
        }
        if lower <= upper { intervals.append((lower, upper)) }
    }
    intervals.sort { $0.0 < $1.0 }
    var covered = 0.0
    for (lower, upper) in intervals {
        if lower > covered + 1e-9 { return false }
        covered = max(covered, upper)
        if covered >= 1 { return true }
    }
    return false
}

// bend/timing仅用于有界变化及确定性测试，不对外增加随机终点或延迟参数。
func makeCursorMotion(from start: CGPoint, to end: CGPoint, displays: [CGRect],
                      bend: Double, timing: Double) throws -> CursorMotion {
    guard [start.x, start.y, end.x, end.y, bend, timing].allSatisfy(\.isFinite),
          !displays.isEmpty, displays.allSatisfy({
              $0.width > 0 && $0.height > 0 && [$0.minX, $0.minY, $0.maxX, $0.maxY].allSatisfy(\.isFinite)
          }), displays.contains(where: { $0.contains(start) }), displays.contains(where: { $0.contains(end) }) else {
        throw cursorMotionFailure()
    }
    let dx = end.x - start.x, dy = end.y - start.y
    let distance = hypot(dx, dy)
    guard distance.isFinite else { throw cursorMotionFailure() }
    if distance == 0 { return CursorMotion(samples: [CursorMotionSample(point: end, time: 0)]) }
    let duration = max(0.15, min(0.7, (0.15 + distance / 2200) * (1 + 0.1 * max(-1, min(1, timing)))))
    let steps = Int(ceil(duration * 60))
    // 同屏内使用曲线；跨屏保持保守直线，保证调度跳过采样后也不会连接出穿屏幕空洞的弦。
    let commonDisplay = displays.first { $0.contains(start) && $0.contains(end) }
    let allowedDisplays = commonDisplay.map { [$0] } ?? displays
    let deviation = commonDisplay == nil ? 0 : min(28, distance * 0.08) * max(-1, min(1, bend))
    // 曲线会越过屏幕边缘时回退直线路径，仍保留平滑的时间缓动，不瞬移到终点。
    for offset in [deviation, 0] {
        let normal = CGPoint(x: -dy / distance * offset, y: dx / distance * offset)
        let a = CGPoint(x: start.x + dx / 3 + normal.x, y: start.y + dy / 3 + normal.y)
        let b = CGPoint(x: start.x + dx * 2 / 3 + normal.x * 0.7, y: start.y + dy * 2 / 3 + normal.y * 0.7)
        let samples = (0...steps).map { index -> CursorMotionSample in
            let u = Double(index) / Double(steps)
            let t = u * u * u * (10 + u * (-15 + 6 * u))
            let v = 1 - t
            let point: CGPoint
            if index == 0 { point = start }
            else if index == steps { point = end }
            else {
                point = CGPoint(x: v * v * v * start.x + 3 * v * v * t * a.x + 3 * v * t * t * b.x + t * t * t * end.x,
                                y: v * v * v * start.y + 3 * v * v * t * a.y + 3 * v * t * t * b.y + t * t * t * end.y)
            }
            return CursorMotionSample(point: point, time: duration * u)
        }
        if samples.allSatisfy({ sample in allowedDisplays.contains { $0.contains(sample.point) } }) &&
            zip(samples, samples.dropFirst()).allSatisfy({ cursorSegmentIsVisible($0.point, $1.point, displays: allowedDisplays) }) {
            return CursorMotion(samples: samples)
        }
    }
    throw cursorMotionFailure()
}

// 每次小步等待都检查中断；事件投递仍由原InputCancellation的提交锁保护。
func playCursorMotion(_ motion: CursorMotion, check: () throws -> Void, emit: (CGPoint) throws -> Void,
                      clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                      sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws {
    let started = clock()
    for (index, sample) in motion.samples.enumerated() {
        try check()
        let deadline = started + sample.time
        while true {
            let remaining = deadline - clock()
            if remaining <= 0 { break }
            sleep(min(0.005, remaining))
            try check()
        }
        // 调度迟到不突发补齐所有过时点；最后一帧仍精确投递到原目标。
        if index + 1 < motion.samples.count && started + motion.samples[index + 1].time <= clock() { continue }
        try check()
        try emit(sample.point)
    }
    try check()
}
