import Foundation

func require(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func fails(_ code: String, _ operation: () throws -> Void) {
    do { try operation(); require(false, "应拒绝：\(code)") }
    catch let failure as HelperFailure { require(failure.code == code, "暂停与取消必须区分") }
    catch { require(false, "意外错误") }
}
final class TestClock {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value += seconds }
}

// Given 首次接管，Then 显示倒计时前后均不能提早取得输入凭据，倒计时移动鼠标不暂停。
let firstClock = TestClock()
let pending = InputCancellation(clock: firstClock.now)
let firstGeneration = pending.snapshot()
let firstEpoch = pending.inputSnapshot()
let firstLease = try pending.beginExecution(generation: firstGeneration)
fails("TAKEOVER_PENDING") { _ = try pending.beginInput(generation: firstGeneration) }
firstClock.advance(10)
fails("TAKEOVER_PENDING") { _ = try pending.beginInput(generation: firstGeneration) }
require(pending.startCountdown(lease: firstLease), "显示控制条后可开始倒计时")
require(pending.executionState(lease: firstLease) == .countdown(3), "从实际展示起计满三秒")
require(!pending.pauseForUserInteraction(lease: firstLease, timestamp: firstClock.now()), "倒计时移动鼠标不暂停")
firstClock.advance(1)
require(pending.executionState(lease: firstLease) == .countdown(2), "应显示两秒")
require(pending.startCountdown(lease: firstLease), "重复展示沿用同一倒计时")
firstClock.advance(1)
require(pending.executionState(lease: firstLease) == .countdown(1), "重复展示不能把倒计时重置")
fails("TAKEOVER_PENDING") { _ = try pending.beginInput(generation: firstGeneration) }
let ready = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    do {
        let permit = try pending.waitForInput(generation: firstGeneration, expectedEpoch: firstEpoch)
        _ = try pending.inputEffect(permit: permit) { ready.signal() }
    } catch { require(false, "有效首次动作应在三秒后自动接管，无需用户点击") }
}
require(ready.wait(timeout: .now() + 0.05) == .timedOut, "满三秒前不能投递输入")
let oldPointerTime = firstClock.now()
firstClock.advance(1)
require(ready.wait(timeout: .now() + 1) == .success, "三秒后必须自动解除等待")
require(pending.executionState(lease: firstLease) == .running, "倒计时结束进入运行")
require(!pending.pauseForUserInteraction(lease: firstLease, timestamp: oldPointerTime), "迟到的倒计时事件不能重新暂停")
require(pending.pauseForUserInteraction(lease: firstLease, timestamp: firstClock.now()), "运行后用户移动立即暂停")
firstClock.advance(20)
require(pending.executionState(lease: firstLease) == .paused, "主动暂停不能超时自动恢复")

let clock = TestClock()
let control = InputCancellation(clock: clock.now)
let generation = control.snapshot()
let lease = try control.beginExecution(generation: generation)
control.startCountdown(lease: lease)
clock.advance(3)
var permit = try control.beginInput(generation: generation)
try control.inputEffect(permit: permit) { }
// Given 用户接管鼠标，Then 已有输入中断，但只读观察不被取消。
require(control.pauseExecution(lease: lease), "有效控制可暂停")
require(control.executionPaused(lease: lease) == true, "暂停状态可读取")
fails("USER_PAUSED") { try control.checkInput(permit) }
fails("USER_PAUSED") { try control.inputEffect(permit: permit) { require(false, "暂停后不能输入") } }
fails("USER_PAUSED") { _ = try control.beginInput(generation: generation) }
try control.effect(generation: generation) { }
// Given 用户点击执行，Then 不自动恢复旧输入，仅允许新的串行操作。
require(control.resumeExecution(lease: lease), "有效控制可恢复")
fails("TAKEOVER_PENDING") { _ = try control.beginInput(generation: generation) }
clock.advance(3)
fails("USER_PAUSED") { try control.checkInput(permit) }
permit = try control.beginInput(generation: generation)
try control.checkInput(permit)
let value = try control.inputEffect(permit: permit) { 42 }
require(value == 42, "新输入允许执行")
// Given 请求已排队尚未开始，When 用户暂停后执行，Then 旧请求不能获得新输入凭据。
let queuedEpoch = control.inputSnapshot()
require(control.pauseExecution(lease: lease), "排队期间暂停")
require(control.resumeExecution(lease: lease), "排队期间执行")
fails("TAKEOVER_PENDING") { _ = try control.beginInput(generation: generation) }
clock.advance(3)
fails("USER_PAUSED") { _ = try control.beginInput(generation: generation, expectedEpoch: queuedEpoch) }
permit = try control.beginInput(generation: generation, expectedEpoch: control.inputSnapshot())
// Given 暂停期间收到的请求仍在队列中，When 用户点击执行，Then 该请求也必须作废。
require(control.pauseExecution(lease: lease), "等待期间暂停")
let pausedEpoch = control.inputSnapshot()
require(control.resumeExecution(lease: lease), "用户点击执行")
fails("TAKEOVER_PENDING") { _ = try control.beginInput(generation: generation) }
clock.advance(3)
fails("USER_PAUSED") { _ = try control.beginInput(generation: generation, expectedEpoch: pausedEpoch) }
permit = try control.beginInput(generation: generation, expectedEpoch: control.inputSnapshot())
// Given 连续暂停/执行，Then 每次都使旧动作不可重放。
require(control.pauseExecution(lease: lease), "再次暂停")
require(control.resumeExecution(lease: lease), "再次执行")
fails("TAKEOVER_PENDING") { _ = try control.beginInput(generation: generation) }
clock.advance(3)
fails("USER_PAUSED") { try control.inputEffect(permit: permit) { } }
permit = try control.beginInput(generation: generation)
// Given 取消，Then 关闭原 toast、旧回调无权操作新连接。
var ended = 0
require(control.onExecutionEnd(lease: lease, handler: { require(control.executionPaused(lease: lease) == nil, "结束回调必须在锁外执行"); ended += 1 }), "可注册结束清理")
control.cancel()
require(ended == 1 && control.executionPaused(lease: lease) == nil, "取消清理控制条")
fails("CANCELLED") { try control.checkInput(permit) }
let nextGeneration = control.snapshot()
let nextLease = try control.beginExecution(generation: nextGeneration)
require(nextLease != lease, "新连接必须使用新 lease")
require(!control.pauseExecution(lease: lease) && !control.resumeExecution(lease: lease), "迟到按钮不能修改新连接")
require(!control.onExecutionEnd(lease: lease, handler: { ended += 100 }), "迟到清理不能绑定新控制")
require(control.executionPaused(lease: nextLease) == false, "旧回调不影响新控制")
control.startCountdown(lease: nextLease)
clock.advance(3)
let nextPermit = try control.beginInput(generation: nextGeneration)
try control.checkInput(nextPermit)
// Given 输入副作用已经进入提交锁，When 用户暂停，Then 暂停返回前先结束该副作用，之后禁止旧输入。
let concurrent = InputCancellation(clock: clock.now)
let concurrentGeneration = concurrent.snapshot()
let concurrentLease = try concurrent.beginExecution(generation: concurrentGeneration)
concurrent.startCountdown(lease: concurrentLease)
clock.advance(3)
let concurrentPermit = try concurrent.beginInput(generation: concurrentGeneration)
let entered = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
let paused = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    do {
        try concurrent.inputEffect(permit: concurrentPermit) {
            entered.signal()
            require(finish.wait(timeout: .now() + 3) == .success, "副作用未释放")
        }
        require(paused.wait(timeout: .now() + 3) == .success, "暂停未完成")
        fails("USER_PAUSED") { try concurrent.inputEffect(permit: concurrentPermit) { } }
        completed.signal()
    } catch { require(false, "副作用运行异常") }
}
require(entered.wait(timeout: .now() + 3) == .success, "副作用未进入")
DispatchQueue.global().async { _ = concurrent.pauseExecution(lease: concurrentLease); paused.signal(); paused.signal() }
require(paused.wait(timeout: .now() + 0.05) == .timedOut, "暂停过早返回")
finish.signal()
require(paused.wait(timeout: .now() + 3) == .success, "暂停锁未释放")
require(completed.wait(timeout: .now() + 3) == .success, "旧输入未结束")
// Given 倒计时中的取消，Then 等待动作立即失败，旧开始/恢复回调不能接管新 lease。
let stopped = InputCancellation()
let stoppedGeneration = stopped.snapshot()
let stoppedLease = try stopped.beginExecution(generation: stoppedGeneration)
stopped.startCountdown(lease: stoppedLease)
let stoppedWait = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    fails("CANCELLED") { _ = try stopped.waitForInput(generation: stoppedGeneration) }
    stoppedWait.signal()
}
stopped.cancel()
require(stoppedWait.wait(timeout: .now() + 1) == .success, "倒计时取消不能等待三秒或产生输入")
require(!stopped.startCountdown(lease: stoppedLease) && !stopped.resumeExecution(lease: stoppedLease), "旧倒计时不能复活")
let cancelled = InputCancellation(clock: clock.now)
let cancelledGeneration = cancelled.snapshot()
let cancelledLease = try cancelled.beginExecution(generation: cancelledGeneration)
cancelled.startCountdown(lease: cancelledLease)
require(cancelled.pauseExecution(lease: cancelledLease), "倒计时取消按钮必须关闭输入")
clock.advance(30)
fails("USER_PAUSED") { _ = try cancelled.waitForInput(generation: cancelledGeneration) }
require(cancelled.executionState(lease: cancelledLease) == .paused, "取消后旧截止时间不能恢复接管")
print("PASS: 首次自动三秒接管、延迟事件过滤、取消与暂停保持、恢复三秒门禁、执行/暂停门禁、旧输入不可重放、只读观察、取消与迟到回调 BDD；未投递系统输入")
