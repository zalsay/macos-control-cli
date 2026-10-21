import Foundation
import Darwin

// 仅运行内存中的 fake effect，不创建事件，不查询或操作真实 AX/Chrome。
private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private final class Trace {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append(value)
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

private func expectCancelled(_ operation: () throws -> Void) {
    do {
        try operation()
        require(false, "取消 ACK 后仍然接受旧 generation 的副作用")
    } catch let error as HelperFailure {
        require(error.code == "CANCELLED", "拒绝旧 generation 时应返回 CANCELLED")
    } catch {
        require(false, "旧 generation 返回了意外错误")
    }
}

// Given 已取消的 generation，When 提交任意后续 effect，Then 闭包完全不执行。
private func rejectsEffectsAfterAcknowledgement() throws {
    let cancellation = InputCancellation()
    let generation = cancellation.snapshot()
    let trace = Trace()
    cancellation.cancel()
    for step in ["Activate", "SetFocused", "SetMain", "Raise"] {
        expectCancelled {
            try cancellation.effect(generation: generation) { trace.append(step) }
        }
    }
    require(trace.snapshot().isEmpty, "旧 generation 的 fake AX 操作被执行")
    let value = try cancellation.effect(generation: cancellation.snapshot()) { 42 }
    require(value == 42, "新 generation 应返回同步 effect 的结果")
}

// Given 第一个 setter 仍在执行，When 另一线程取消，Then 必须先完成该 effect 才能 ACK。
// And ACK 后，同一 fake AX 链后续的 SetMain / Raise 均不能再提交。
private func acknowledgementWaitsForEnteredEffect() throws {
    let cancellation = InputCancellation()
    let generation = cancellation.snapshot()
    let trace = Trace()
    let entered = DispatchSemaphore(value: 0)
    let finishEffect = DispatchSemaphore(value: 0)
    let cancelStarted = DispatchSemaphore(value: 0)
    let acknowledgement = DispatchSemaphore(value: 0)
    let chainFinished = DispatchSemaphore(value: 0)
    let actions = DispatchQueue(label: "copis.tests.fake-ax-actions")
    let cancels = DispatchQueue(label: "copis.tests.fake-cancel")

    actions.async {
        defer { chainFinished.signal() }
        do {
            try cancellation.effect(generation: generation) {
                trace.append("SetFocused.begin")
                entered.signal()
                require(finishEffect.wait(timeout: .now() + 3) == .success, "fake effect 等待释放超时")
                trace.append("SetFocused.end")
            }
            // 主动把后续步骤放到 ACK 后，以确定性捕获此前 setter 链的问题。
            require(acknowledgement.wait(timeout: .now() + 3) == .success, "取消没有在当前 effect 结束后 ACK")
            try cancellation.effect(generation: generation) { trace.append("SetMain") }
            try cancellation.effect(generation: generation) { trace.append("Raise") }
            trace.append("unexpected.success")
        } catch let error as HelperFailure {
            trace.append(error.code)
        } catch {
            trace.append("unexpected.error")
        }
    }
    require(entered.wait(timeout: .now() + 3) == .success, "第一个 fake setter 未开始执行")
    cancels.async {
        cancelStarted.signal()
        cancellation.cancel()
        trace.append("cancel.ack")
        // 分别供主测试线程及 fake action 链观察 ACK，不相互消费信号。
        acknowledgement.signal()
        acknowledgement.signal()
    }
    require(cancelStarted.wait(timeout: .now() + 3) == .success, "取消线程未开始执行")
    let earlyAcknowledgement = acknowledgement.wait(timeout: .now() + 0.1)
    finishEffect.signal()
    require(earlyAcknowledgement == .timedOut, "当前 effect 未结束就返回了取消 ACK，副作用与 cancel 没有共用提交锁")
    require(acknowledgement.wait(timeout: .now() + 3) == .success, "当前 effect 结束后取消仍未 ACK")
    require(chainFinished.wait(timeout: .now() + 3) == .success, "fake AX 链在取消后未及时结束")
    require(trace.snapshot() == ["SetFocused.begin", "SetFocused.end", "cancel.ack", "CANCELLED"],
            "取消 ACK 前后发生了错误的副作用顺序")
}

private enum FakeFailure: Error { case expected }

// Given effect 闭包抛错，Then 原错误向上传播且提交锁必定释放。
private func throwingEffectReleasesTheLock() throws {
    let cancellation = InputCancellation()
    let generation = cancellation.snapshot()
    do {
        try cancellation.effect(generation: generation) { throw FakeFailure.expected }
        require(false, "effect 吞掉了闭包错误")
    } catch FakeFailure.expected { }
    cancellation.cancel()
    expectCancelled { try cancellation.effect(generation: generation) { } }
    let value = try cancellation.effect(generation: cancellation.snapshot()) { "new-generation" }
    require(value == "new-generation", "闭包抛错后锁未正确释放")
}

try rejectsEffectsAfterAcknowledgement()
try acknowledgementWaitsForEnteredEffect()
try throwingEffectReleasesTheLock()
print("PASS: 3 项纯 fake effect BDD 回归；未调用真实 AX、未创建或投递输入事件")
