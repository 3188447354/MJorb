import Foundation
import Testing
@testable import Seal

/// `ContinuationBox` 存在的唯一理由：`CheckedContinuation` 第二次 resume **不是可捕获的错误**，
/// 而是 `SWIFT TASK CONTINUATION MISUSE` 致命崩溃（进程直接终止）。
///
/// AltSign 的回调链路是真实风险源：同一个完成回调可能先报错、随后迟到地再报成功；
/// 超时先到之后底层回调仍会继续调用 continuation。Portal 三个服务的 22 个回调点
/// 此前把裸 continuation 直接交给了 ALTAppleAPI（见 DEBUG_LOG 坑位 16）。
///
/// 这些用例若失败，表现是**测试进程崩溃**而不是断言失败 —— 这正是要防的形态。
struct ContinuationBoxTests {
    /// 最核心用例：重复回调只允许第一个生效，且不得崩溃。
    @Test
    func duplicateCallbacksOnlyFirstResultWins() async throws {
        let result: Int = try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox<Int>(continuation)
            box.resume(returning: 1)
            // 迟到/重复回调：没有盒子时，这里就是致命崩溃点
            box.resume(returning: 2)
            box.resume(throwing: URLError(.timedOut))
        }
        #expect(result == 1)
    }

    /// 先到的是错误：必须抛错误，且随后的“成功”回调被丢弃。
    @Test
    func errorArrivingFirstWinsAndLaterSuccessIsDropped() async {
        struct Boom: Error {}
        var caughtBoom = false
        do {
            let _: Int = try await withCheckedThrowingContinuation { continuation in
                let box = ContinuationBox<Int>(continuation)
                box.resume(throwing: Boom())
                box.resume(returning: 99)
            }
        } catch is Boom {
            caughtBoom = true
        } catch {
            Issue.record("期望 Boom，实际抛出 \(error)")
        }
        #expect(caughtBoom)
    }

    /// Void 特化：`revoke` / `deleteProvisioningProfile` / `assign` 三处都是
    /// `CheckedContinuation<Void, Error>`，走的是 `resume()` 而不是 `resume(returning:)`。
    @Test
    func voidBoxResumesAndDropsRepeatedCallback() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            let box = ContinuationBox(continuation)
            box.resume()
            box.resume()
            box.resume(throwing: URLError(.badServerResponse))
        }
    }

    /// 并发回调：多个线程同时 resume，只能有一个胜出，且不得因数据竞争崩溃。
    @Test
    func concurrentCallbacksResolveExactlyOnce() async throws {
        let result: Int = try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox<Int>(continuation)
            DispatchQueue.concurrentPerform(iterations: 32) { index in
                box.resume(returning: index)
            }
        }
        #expect((0..<32).contains(result))
    }

    /// 真实场景复刻：`HardTimeout` 先超时抛出，底层回调随后才到。
    /// 超时不会阻止迟到回调调用 continuation，此时盒子必须把这次调用安全丢弃。
    @Test
    func lateCallbackAfterTimeoutIsSafelyDropped() async {
        var timedOut = false
        do {
            try await HardTimeout.run(seconds: 0.1) {
                try await withCheckedThrowingContinuation { continuation in
                    let box = ContinuationBox<Void>(continuation)
                    Task.detached {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        // 超时错误此刻已经抛给调用方了，这次 resume 必须被丢弃
                        box.resume()
                    }
                }
            }
        } catch is HardTimeout.TimeoutError {
            timedOut = true
        } catch {
            Issue.record("期望 TimeoutError，实际抛出 \(error)")
        }
        #expect(timedOut)
        // 等迟到回调真正执行完；盒子失效的话这里会崩进程
        try? await Task.sleep(nanoseconds: 800_000_000)
    }
}
