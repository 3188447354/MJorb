import Foundation

/// 回调式 API 的「只恢复一次」状态盒。
///
/// `CheckedContinuation` 只允许 resume 一次；第二次 resume **不是可捕获的错误**，
/// 而是直接触发 `SWIFT TASK CONTINUATION MISUSE` 致命崩溃（进程被终止，没有可捕获的
/// 堆栈，只能从崩溃日志里看到一句 "resumed, but it was already resumed"）。
///
/// 这在 AltSign 回调链路上是真实风险，不是理论问题：
/// - ALTAppleAPI 的成功/失败回调可能都会触发（例如先回调一次网络错误、随后迟到地再回调成功）；
/// - 超时先到时，`HardTimeout` 只放弃自己那一层的等待，**不会**阻止底层回调继续调用
///   continuation —— 于是「超时错误已抛出」与「迟到回调又 resume 一次」会撞在一起。
///
/// 所以凡是把 `CheckedContinuation` 交给第三方回调的地方，都必须经过本盒转发：
/// 第一个到达的结果获胜并清空，后续调用取到 nil 后安全丢弃。
///
/// 同一模式在本仓已有两处实现，此处抽出为共享类型供 Portal 三个服务复用：
/// `AppleAccountClient.LegacyCallbackBox`（账号链路）与 `HardTimeout.RaceState`（超时竞速）。
final class ContinuationBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        take()?.resume(throwing: error)
    }

    func resume(with result: Result<Value, any Error>) {
        take()?.resume(with: result)
    }

    /// 取出并清空待恢复的 continuation；已被别人取走时返回 nil（迟到的重复回调）。
    private func take() -> CheckedContinuation<Value, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        let pending = continuation
        continuation = nil
        return pending
    }
}

extension ContinuationBox where Value == Void {
    /// 等价于 `CheckedContinuation<Void, Error>.resume()`：成功即返回空值。
    func resume() {
        resume(returning: ())
    }
}
