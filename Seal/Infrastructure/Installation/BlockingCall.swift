import Foundation

/// 在**后台线程**执行可能永久阻塞的同步 FFI，并带**硬超时**。
///
/// ## 为什么必须有它
///
/// 本仓的同步 FFI（`Minimuxer.*` / `Provision.*` / `Device.*` / `RustIdevice.*`）**没有取消机制**：
/// 在一条已经死掉的 RSD 缓存会话上调用它，**不报错、只阻塞到操作系统放弃**
/// （2026-09-17 真机实测：普通安装静默 9 分多钟，日志里一行都没有）。
///
/// ⇒ **凡是 `await` 这类调用的地方都要问「它不返回会怎样」**（本仓明文规则）。
/// 只有 `Task.detached` 是不够的 —— 那只把它挪出主线程，**阻塞本身仍然无界**。
///
/// ## 超时后的语义
///
/// 超时**只表示「本次放弃等待」**，FFI 仍在后台跑完、结果被丢弃（同步调用响应不了取消）。
/// 所以：
/// - 对**查询类**调用（`isAppInstalled` 等）安全 —— 没有副作用要撤销；
/// - 对**有副作用的调用**（安装、删除）要谨慎，见 `MinimuxerInstallChannel` 的
///   `cancelsWorkOnTimeout` 说明与 R05。
enum BlockingCall {
    /// 设备端**查询类**调用的默认上限。
    ///
    /// 查询正常是亚秒级；15 秒已经非常宽松 —— 它的唯一用途是把「永久阻塞」变成
    /// 「有界失败」。与 `Provision.dumpProfiles` 内部的 `deviceFetchTimeoutMs`（15 秒）同量级。
    static let queryTimeoutSeconds: Double = 15

    /// Result 的 Failure 侧（`any Error`）不保证 Sendable，用 `@unchecked` 穿过竞速边界。
    private struct Outcome<T: Sendable>: @unchecked Sendable {
        let result: Result<T, Error>
    }

    /// 在后台执行 `work`；超过 `seconds` 未返回则返回 `nil`（本次放弃）。
    ///
    /// - Returns: 成功/失败都装在 `Result` 里；**超时**返回 `nil`。
    ///   调用方必须把 `nil` 当成「不知道」，**不能**当成「否」（判据的错法方向决定安全）。
    static func bounded<T: Sendable>(
        seconds: Double,
        _ work: @Sendable @escaping () throws -> T
    ) async -> Result<T, Error>? {
        do {
            let outcome: Outcome<T> = try await HardTimeout.run(seconds: seconds) {
                Outcome(result: Result(catching: work))
            }
            return outcome.result
        } catch {
            // 抛错只可能是超时（工作结果/错误都装在 Result 里返回）。
            return nil
        }
    }

    /// 与 `bounded` 同源，但把超时**抛成错误** —— 供已经用 `try` 组织的调用点使用。
    static func throwingBounded<T: Sendable>(
        seconds: Double,
        timeoutError: @autoclosure () -> Error,
        _ work: @Sendable @escaping () throws -> T
    ) async throws -> T {
        guard let outcome = await bounded(seconds: seconds, work) else {
            throw timeoutError()
        }
        return try outcome.get()
    }
}
