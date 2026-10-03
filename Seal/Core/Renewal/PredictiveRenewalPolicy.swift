import Foundation

/// 预测式后台续签的准入（2026-10-03，续签提速）—— **纯函数，可单测**。
///
/// 背景：快捷指令触发的后台轮原来**每轮全量**续签所有已安装应用 ——
///
/// 每个应用都要走一遍 portal（读团队/设备/App ID 列表 + 下载描述文件）与设备注入，
/// 3 个应用就是 3 倍请求量，既慢又给 Apple 限流（1100）添堵。而免费描述文件寿命
/// 7 天，**绝大多数**应用在绝大多数轮次里根本不需要续。
///
/// ⇒ 后台轮只处理「窗口内会过期」的；手动「续签全部」**不受影响**（照旧全量）。
/// 用户感知的「续签速度」= 每一轮实际要做的事变少了；Apple 侧压力也下来了。
enum PredictiveRenewalPolicy {
    /// 基准窗口：48 小时。免费 profile 7 天寿命，48 小时留足了「本轮失败 → 下轮重试」
    /// 的余量（见 `backgroundWindow(lastRun:now:)` 的自适应放宽）。
    static let baseWindow: TimeInterval = 48 * 3600

    /// 本轮后台续签的时间窗口（纯函数）。
    ///
    /// - Parameter lastRun: 上一次**后台预测式**续签跑完的时间（nil = 没跑过）。
    /// - Returns: `max(48h, 上次间隔 + 24h)` —— 触发频率低时自动放宽：
    ///   快捷指令每天跑 ⇒ 窗口 48h；每周跑一次 ⇒ 窗口约 8 天 ≈ 全量，
    ///   **不会**因为「上周没到期被跳过、这周已过期」而漏续。
    ///   这是对「低频自动化用户」的回退保护，不是给高频用户加活。
    static func backgroundWindow(
        lastRun: Date?,
        now: Date = Date()
    ) -> TimeInterval {
        guard let lastRun else { return baseWindow }
        return max(baseWindow, now.timeIntervalSince(lastRun) + 24 * 3600)
    }

    /// 该应用本轮后台续签要不要进队列（纯函数）。
    ///
    /// - 未知过期时间 ⇒ 进（fail open：宁可多续一次，不让它悄悄过期；
    ///   记录损坏时「多做一次 profile-only」远好于「看着它死」）。
    /// - 不在已安装列表 ⇒ 不进（与 `RefreshPlanner.makeQueue` 的过滤同源）。
    /// - `requiresAction` 的项（缺账号等）**不过滤** —— 它们不发 portal 请求（零成本），
    ///   且是用户需要被提醒的前置条件，滤掉等于静默。
    static func needsBackgroundRenewal(
        app: AppRecord,
        now: Date = Date(),
        window: TimeInterval = baseWindow
    ) -> Bool {
        guard app.belongsInInstalledList else { return false }
        guard let expiry = app.expiryDate else { return true }
        return expiry.timeIntervalSince(now) < window
    }
}
