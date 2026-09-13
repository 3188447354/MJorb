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
}
