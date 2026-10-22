import Foundation
import CoreGraphics

func require(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func fails(_ code: String, _ operation: () throws -> Void) {
    do { try operation(); require(false, "应拒绝 \(code)") }
    catch let error as HelperFailure { require(error.code == code, "错误应保留 \(code)，实际\(error.code)") }
    catch { require(false, "意外错误") }
}
let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
let start = CGPoint(x: 100, y: 100), end = CGPoint(x: 1100, y: 600)
let path = try makeCursorMotion(from: start, to: end, displays: [screen], bend: 0.7, timing: 0)
require(path.samples.first?.point == start && path.samples.last?.point == end, "精确保留当前光标起点和请求终点")
require(path.duration >= 0.15 && path.duration <= 0.7 && path.samples.count > 8, "有界时长和连续中间点")
require(path.samples.first?.time == 0 && path.samples.last?.time == path.duration, "采样覆盖完整时长")
require(path.samples.contains { abs(($0.point.x - start.x) * (end.y - start.y) - ($0.point.y - start.y) * (end.x - start.x)) > 1 }, "存在轻微曲率而非瞬移")
require(zip(path.samples, path.samples.dropFirst()).allSatisfy { $0.time < $1.time }, "采样时间严格递增")
let distances = zip(path.samples, path.samples.dropFirst()).map { hypot($1.point.x - $0.point.x, $1.point.y - $0.point.y) }
require(distances.first! < distances[distances.count / 2] && distances.last! < distances[distances.count / 2], "启动和停止慢于中段")
let dx = end.x - start.x, dy = end.y - start.y
let projected = path.samples.map { (($0.point.x - start.x) * dx + ($0.point.y - start.y) * dy) / (dx * dx + dy * dy) }
require(projected.allSatisfy { $0 >= -1e-9 && $0 <= 1 + 1e-9 } && zip(projected, projected.dropFirst()).allSatisfy { $0 <= $1 }, "不纵向过冲，不回头修正")
for bend in [-1.0, 0, 1.0] {
    let edge = try makeCursorMotion(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 1599, y: 0), displays: [screen], bend: bend, timing: 1)
    require(edge.samples.allSatisfy { screen.contains($0.point) }, "屏幕边缘轨迹不能越界")
}
let still = try makeCursorMotion(from: start, to: start, displays: [screen], bend: 1, timing: 0)
require(still.duration == 0 && still.samples.count == 1 && still.samples[0].point == start, "同坐标不添加虚假抖动")
let short = try makeCursorMotion(from: start, to: CGPoint(x: 101, y: 100), displays: [screen], bend: -1, timing: -1)
require(short.duration >= 0.15 && short.samples.last?.point == CGPoint(x: 101, y: 100), "短距离也保留精确终点")
let left = CGRect(x: -1000, y: 0, width: 1000, height: 1000)
let cross = try makeCursorMotion(from: CGPoint(x: -800, y: 300), to: CGPoint(x: 400, y: 300), displays: [left, screen], bend: 1, timing: 0)
require(cross.samples.first?.point.x == -800 && cross.samples.last?.point.x == 400, "支持负坐标屏幕，不翻转Y轴")
// 跨屏使用保守直线；不能让调度丢帧把绕过凹角的曲线重新连接成穿越空洞的线段。
let steppedDisplays = [CGRect(x: 0, y: 0, width: 400, height: 400), CGRect(x: 400, y: 200, width: 400, height: 400)]
fails("INPUT_FAILED") { _ = try makeCursorMotion(from: CGPoint(x: 200, y: 390), to: CGPoint(x: 600, y: 430), displays: steppedDisplays, bend: -1, timing: 0) }
let gapDisplays = [CGRect(x: 0, y: 0, width: 300, height: 300), CGRect(x: 600, y: 0, width: 300, height: 300)]
fails("INPUT_FAILED") { _ = try makeCursorMotion(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 700, y: 100), displays: gapDisplays, bend: 0, timing: 0) }
fails("INPUT_FAILED") { _ = try makeCursorMotion(from: start, to: end, displays: [], bend: 0, timing: 0) }
fails("INPUT_FAILED") { _ = try makeCursorMotion(from: CGPoint(x: CGFloat.nan, y: 0), to: end, displays: [screen], bend: 0, timing: 0) }

// 使用fake时钟/投递运行生产调度器，不产生真实系统输入。
var time: TimeInterval = 10, emitted: [CGPoint] = [], checks = 0
try playCursorMotion(path, check: { checks += 1 }, emit: { emitted.append($0) }, clock: { time }, sleep: { time += $0 })
require(emitted.first == start && emitted.last == end && emitted.count == path.samples.count, "正常调度按轨迹投递并精确到达终点")
require(checks > emitted.count && time >= 10 + path.duration, "等待期间持续检查，不能提早到达")
var blocked = false, afterCancel: [CGPoint] = [], clicks = 0
time = 20
fails("CANCELLED") {
    try playCursorMotion(path, check: { if blocked { throw HelperFailure.cancelled } }, emit: { afterCancel.append($0); blocked = true }, clock: { time }, sleep: { time += $0 })
    clicks += 1
}
require(afterCancel.count == 1 && clicks == 0, "移动途中取消后不能继续移动或发送点击")
for code in ["USER_PAUSED", "FOCUS_LOST", "IMAGE_GEOMETRY_CHANGED"] {
    var interrupted = false, count = 0
    time = 30
    fails(code) {
        try playCursorMotion(path, check: { if interrupted { throw HelperFailure(code: code, message: "状态已变化") } }, emit: { _ in count += 1 }, clock: { time }, sleep: { time += $0; interrupted = true })
        clicks += 1
    }
    require(count == 1 && clicks == 0, "等待期间\(code)必须中止后续移动与点击")
}
var delayed: [CGPoint] = []
time = 40
try playCursorMotion(path, check: {}, emit: { delayed.append($0); time += 0.08 }, clock: { time }, sleep: { time += $0 })
require(delayed.last == end && delayed.count < path.samples.count, "调度迟到时丢弃过时中间点，不补发突发事件")
print("PASS: Bézier/minimum-jerk曲线、原点/终点/速度/屏幕边界/跨屏、调度、取消/暂停/失焦/几何变化与不突发补帧 BDD；未投递系统输入")
