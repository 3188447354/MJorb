import Foundation

struct RefreshQueueItem: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case pending
        case running
        case completed
        case failed
        /// 进程在「运行中」被杀（崩溃 / 被系统回收），结果未知。
        ///
        /// **既不能当成功、也不能当失败**：签名+安装可能已经落地，也可能只做了一半。
        /// 必须先核验（或至少让用户知情）才允许再动它。旧的实现没有这个状态，
        /// 被中断的项会永久停在 `running`：既不在失败列表里不会被重试，
        /// 也不是 `completed` 不会被清理 —— 用户看到的是一批「永远在跑」的幽灵条目。
        case unknown
        /// 本轮**根本不会执行**，等用户先做决定（缺可用账号、多候选无法唯一确定等）。
        ///
        /// 与 `failed` 的区别：失败是「试过了没成」，这里是「没试，因为缺前置条件」。
        /// 旧实现直接在 planner 里 `return nil` 静默省略，于是「批量续签完成」看起来
        /// 一切正常，实际有应用根本没被处理。
        case requiresAction
    }

    let id: UUID
    let appID: UUID
    /// 可空：`requiresAction` 的项没有可确定的账号，此时不该硬塞一个占位值。
    let accountID: UUID?
    var state: State
    var lastErrorCode: String?
    /// `requiresAction` 的原因（面向用户，必须是可执行的引导，不能只说「跳过」）。
    var requiresActionReason: String?

    init(
        id: UUID = UUID(),
        appID: UUID,
        accountID: UUID?,
        state: State = .pending,
        lastErrorCode: String? = nil,
        requiresActionReason: String? = nil
    ) {
        self.id = id
        self.appID = appID
        self.accountID = accountID
        self.state = state
        self.lastErrorCode = lastErrorCode
        self.requiresActionReason = requiresActionReason
    }

    /// 本轮结束后仍需处理的项：失败、未执行、结果未知。
    ///
    /// 已完成的不算 —— 「恢复不能重做已成功的项」这条不变量的落点就在这里。
    var needsFollowUp: Bool {
        switch state {
        case .completed: return false
        case .pending, .running, .failed, .unknown, .requiresAction: return true
        }
    }

    /// 可以交给签名流程执行（账号已确定、且本轮确实要跑）。
    var isExecutable: Bool {
        state != .requiresAction && accountID != nil
    }
}
