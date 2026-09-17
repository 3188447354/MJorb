import Foundation
import Testing
@testable import Seal

/// `HardTimeout` 存在的唯一理由：被超时的操作若**无法响应取消**（ALTAppleAPI 回调不返回、
/// 同步 FFI 卡住），超时也必须照常抛出。
///
/// 用 `withThrowingTaskGroup` 做不到这一点 —— 任务组退出前必须等所有子任务结束，
/// `cancelAll()` 只能设协作取消标记，于是超时错误被无限期拖住，等于没有超时。
/// 这正是 `ApplePortalSigningService.withAppleTimeout` 此前的写法（见 DEBUG_LOG 坑位 15）。
struct HardTimeoutTests {
    /// 操作在 3 秒后才恢复，且**不响应 Task 取消**（detached 任务不会被父任务取消）。
    /// 超时预算 0.2 秒，必须远早于 3 秒返回。
    @Test
    func timeoutFiresEvenWhenOperationCannotBeCancelled() async {
        let started = Date()
        var timedOut = false
        do {
            try await HardTimeout.run(seconds: 0.2) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    Task.detached {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        continuation.resume()
                    }
                }
            }
        } catch is HardTimeout.TimeoutError {
            timedOut = true
        } catch {
            Issue.record("期望 TimeoutError，实际抛出 \(error)")
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(timedOut)
        // 关键断言：按预算退出，而不是等操作自己结束（那样就是无限等待）
        #expect(elapsed < 2, "超时未按预算触发，实际耗时 \(elapsed) 秒")
    }

    @Test
    func returnsOperationResultWhenItFinishesFirst() async throws {
        let value = try await HardTimeout.run(seconds: 5) { 42 }
        #expect(value == 42)
    }

    @Test
    func propagatesOperationError() async {
        struct Boom: Error {}
        var caughtBoom = false
        do {
            try await HardTimeout.run(seconds: 5) { throw Boom() }
        } catch is Boom {
            caughtBoom = true
        } catch {
            Issue.record("期望 Boom，实际抛出 \(error)")
        }
        #expect(caughtBoom)
    }

    /// `cancelsWorkOnTimeout: false` 的语义：超时**只停止等待**，绝不取消工作。
    ///
    /// 这是自替换安装（Seal 覆盖运行中的自己）唯一可用的超时形态 ——
    /// `Minimuxer.stageAndInstall` 是同步阻塞 FFI，取消它本身没有意义，而 Rust 侧
    /// 一旦把取消信号当作「调用方放弃」来清理，就会撤销已经下发的 installation_proxy
    /// 命令：那是把「可能还在装」变成「确定装不上」。
    ///
    /// 关键在于断言的是**工作自己所在任务**的取消状态：`HardTimeout` 把 operation
    /// 放进它自己创建的 detached 任务里跑，`cancelsWorkOnTimeout` 控制的就是那个任务。
    /// 若在闭包里再套一层 `Task.detached`，测到的就是新任务的取消状态（永远是 false），
    /// 这个测试会退化成永远通过 —— 所以这里必须让 operation 直接 `await`。
    @Test
    func nonCancellingTimeoutLeavesTheWorkRunning() async {
        let probe = CancellationProbe()
        do {
            try await HardTimeout.run(seconds: 0.05, cancelsWorkOnTimeout: false) {
                // 0.3 秒远长于 0.05 秒预算：超时先到，这里只可能在超时之后才跑到。
                try? await Task.sleep(nanoseconds: 300_000_000)
                probe.record(cancelled: Task.isCancelled)
            }
            Issue.record("期望 TimeoutError")
        } catch is HardTimeout.TimeoutError {
            // 预期：超时按预算抛出，不等工作结束
        } catch {
            Issue.record("期望 TimeoutError，实际抛出 \(error)")
        }
        // 等被遗弃的工作在后台跑完
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(probe.didFinish, "超时后工作应仍在后台跑完，而不是被取消")
        #expect(probe.wasCancelled == false, "cancelsWorkOnTimeout: false 时工作不得被取消")
    }
}

/// 跨任务记录「工作是否跑完 / 是否被取消」。用锁而不是 actor：
/// 它要在 `@Sendable` 闭包里被**同步**写入，actor 会强制 await 并改变时序。
private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var cancelled = false

    func record(cancelled value: Bool) {
        lock.lock()
        finished = true
        cancelled = value
        lock.unlock()
    }

    var didFinish: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
