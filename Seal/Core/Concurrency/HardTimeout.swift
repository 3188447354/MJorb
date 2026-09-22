import Foundation

/// 可遗弃的超时竞速。
///
/// `withThrowingTaskGroup` 实现的超时有一个致命限制：任务组退出前必须等待所有子任务
/// 结束，`cancelAll()` 只能设置协作取消标记。如果被超时的操作卡在无法响应取消的
/// 同步 FFI 里（Unicorn/ADI 模拟、Minimuxer Rust FFI、AltSign 内部回调），
/// 超时错误要一直等 FFI 返回才能抛出，等于没有超时。
///
/// 这里改用非结构化任务：超时先到就直接返回或抛出，输掉竞速的任务被“遗弃”在后台
/// 自行结束，其结果被安全丢弃（continuation 只允许 resume 一次，由锁保证）。
enum HardTimeout {
    struct TimeoutError: Error, LocalizedError, Sendable {
        let seconds: TimeInterval

        var errorDescription: String? {
            "操作超过 \(Int(seconds)) 秒未完成"
        }
    }

    static func run<T: Sendable>(
        seconds: TimeInterval,
        cancelsWorkOnTimeout: Bool = true,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let state = RaceState<T>()
        // 父任务取消必须**立刻**解除挂起：只靠超时或工作自己结束来恢复的话，
        // 「取消一次大包上传」会把 OperationCoordinator 的全局单槽占住好几分钟
        // （调用方的 `defer releaseOperation` 根本走不到）。
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // 必须先同步存入 continuation，再启动竞速任务，保证 resume 永远发生在 store 之后
                state.store(continuation)
                state.start(seconds: seconds, operation: operation, cancelsOnTimeout: cancelsWorkOnTimeout)
            }
        } onCancel: {
            state.cancelByParent()
        }
    }

    /// 锁保护的竞速状态；同一模式见 AppleAccountClient.LegacyCallbackBox。
    /// 获胜方负责 resume；输掉的一方稍后调用 finish 时 continuation 已被清空，安全忽略。
    private final class RaceState<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var timer: Task<Void, Never>?
        private var work: Task<Void, Never>?
        private var cancelsWorkOnTimeout = true
        /// 「谁先落地谁赢」：超时、工作完成、父任务取消三方竞速，
        /// 也用来处理 `onCancel` 早于 `store` 的时序（任务建立前就已被取消）。
        private var settled = false

        func store(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            let alreadySettled = settled
            if alreadySettled == false {
                self.continuation = continuation
            }
            lock.unlock()
            if alreadySettled {
                continuation.resume(throwing: CancellationError())
            }
        }

        func start(
            seconds: TimeInterval,
            operation: @escaping @Sendable () async throws -> T,
            cancelsOnTimeout: Bool
        ) {
            lock.lock()
            guard settled == false else {
                lock.unlock()
                return
            }
            cancelsWorkOnTimeout = cancelsOnTimeout
            let task = Task.detached(priority: .utility) { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch {
                    return // 工作先完成时定时器已被取消
                }
                self?.finish(.failure(TimeoutError(seconds: seconds)))
            }
            timer = task
            let workTask = Task.detached(priority: .userInitiated) { [weak self] in
                let result: Result<T, Error>
                do {
                    result = .success(try await operation())
                } catch {
                    result = .failure(error)
                }
                self?.finish(result)
            }
            work = workTask
            lock.unlock()
        }

        /// 父任务被取消：调用方不再等待，按 `CancellationError` 恢复。
        /// 底层同步 FFI 依旧取消不掉，是否连工作一起取消仍由 `cancelsWorkOnTimeout`
        /// 决定 —— 与超时走同一条判据，避免「取消」反而拆掉正在跑的安装。
        func cancelByParent() {
            lock.lock()
            let timerToCancel = timer
            timer = nil
            lock.unlock()
            timerToCancel?.cancel()
            finish(.failure(CancellationError()))
        }

        private func finish(_ result: Result<T, Error>) {
            lock.lock()
            guard settled == false else {
                lock.unlock()
                return
            }
            settled = true
            let pending = continuation
            continuation = nil
            let timerToCancel = timer
            timer = nil
            let workToCancel = cancelsWorkOnTimeout ? work : nil
            work = nil
            lock.unlock()

            timerToCancel?.cancel()
            workToCancel?.cancel()
            pending?.resume(with: result)
        }
    }
}
