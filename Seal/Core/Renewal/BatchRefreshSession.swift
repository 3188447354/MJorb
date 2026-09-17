import Foundation

struct BatchRefreshSession: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case preparing
        case running
        case preparingSealUpdate
        case completed(BatchRefreshResult)
        case failed(ImportFailure)
    }

    struct Item: Identifiable, Equatable, Sendable {
        enum State: Equatable, Sendable {
            case waiting
            case running
            case completed
            case failed
            case preparingSealUpdate
        }

        let id: UUID
        var name: String
        var isSeal: Bool
        var state: State
        var stage: SigningStage? = nil
    }

    let id: UUID
    var status: Status
    var currentIndex: Int
    var total: Int
    var currentAppName: String?
    var currentStage: SigningStage?
    /// 当前应用上传到设备的真实进度（0-1），仅 `.pushing` 阶段有值。
    var currentInstallProgress: Double?
    /// 进入 `.installing` 的时刻。installd 安装期间**没有任何进度回报**，
    /// 只能靠计时让「还在走」变成可见事实（2026-09-16 真机反馈「卡住没反应」）。
    var installStartedAt: Date?
    var succeeded: Int
    var failed: Int
    var items: [Item]

    init(id: UUID = UUID()) {
        self.id = id
        status = .preparing
        currentIndex = 0
        total = 0
        succeeded = 0
        failed = 0
        items = []
    }
}

extension BatchRefreshSession {
    /// 记录安装通道上传进度。只在 `.pushing` 阶段采信 —— 其它阶段的百分比
    /// 没有分母（`.installing` 之后安装通道不再回传数值），留下来会让 UI 显示
    /// 一个永远不动的旧百分比。
    mutating func recordInstallProgress(_ progress: Double) {
        guard currentStage == .pushing else { return }
        currentInstallProgress = max(0, min(1, progress))
    }

    /// 阶段推进：进入 `.installing` 记下起点供「已等待」计时，离开时清掉，
    /// 避免下一项复用上一项的起点算出「已等待 12 分钟」这种假象。
    ///
    /// 起点规则与单签共用 `InstallStageTimeline`：这条规则以前在
    /// `AppsViewModel.updateSigningStage` 里另有一份拷贝，两处漂移不会编译失败，
    /// 只会让其中一条链路的计时变成假象。
    ///
    /// **把 `Tick` 返回给调用方**，是为了让调用方也能用「是否首次进入该阶段」这个判据。
    /// 批量续签 Seal 时要在进入 `.installing` 后触发「回主页」，而 `.installing` 会被
    /// **重复推送**（安装通道的 >1.0 哨兵一次、签名侧补发一次）—— 不设闸门就会排出多个
    /// 「回主页」任务。先前把这种重复评估为「良性」（第一个任务转场后进程被挂起，后续任务
    /// 不执行；转场失败时第一个 `exit(0)` 已结束进程），但它**每个任务都会写一遍
    /// 「上传完成 / 触发转场」日志**，把真机排查最关键的那段时序信息淹没。
    /// 单签那条链路本来就用同一个闸门，这里与它对齐。
    @discardableResult
    mutating func advanceStage(
        _ stage: SigningStage,
        at now: Date = Date()
    ) -> InstallStageTimeline.Tick {
        let tick = InstallStageTimeline.tick(entering: stage, currentStage: currentStage)
        installStartedAt = InstallStageTimeline.applied(tick, startedAt: installStartedAt, now: now)
        if stage != .pushing {
            currentInstallProgress = nil
        }
        currentStage = stage
        return tick
    }
}

// MARK: - 持久化映射

/// `BatchRefreshSession.Item.State` 与「批量续签结果载荷」之间的字符串映射。
///
/// ## ⚠️ 必须是 `internal`，不能收回成 `private`
///
/// 2026-09-17 踩到：这组映射原先写成 `private extension`（file 级），
/// 只有 `AppsViewModel.swift` 能看见。后来 `PendingBatchResultPayload`（另一个文件）
/// 与它的单测都要用 ⇒ 云构建直接编译失败
/// （`initializer is inaccessible due to 'fileprivate' protection level`）。
///
/// ⇒ 它**本来就该是跨文件的**：写入侧（`persistPendingBatchResult`）与读取侧
/// （`PendingBatchResultPayload`）必须是**同一份**映射，抄两份迟早漂移成
/// 「写进去是 completed、读出来当未知」。
extension BatchRefreshSession.Item.State {
    var storageValue: String {
        switch self {
        case .waiting: return "waiting"
        case .running: return "running"
        case .completed: return "completed"
        case .failed: return "failed"
        case .preparingSealUpdate: return "preparingSealUpdate"
        }
    }

    /// 映射到**续签队列项**的状态；只有「已定论」的两态有值。
    ///
    /// `waiting` / `running` / `preparingSealUpdate` 都没有结论（`running` 尤其：
    /// 进程就是在这个状态下被杀的），返回 `nil` 让调用方按「结果未知」处理。
    /// 把 `running` 也映射上等于**替那个正在被杀死的项宣布结果**。
    var settledQueueState: RefreshQueueItem.State? {
        switch self {
        case .completed: return .completed
        case .failed: return .failed
        case .waiting, .running, .preparingSealUpdate: return nil
        }
    }

    init(storageValue: String?) {
        switch storageValue {
        case "running": self = .running
        case "completed": self = .completed
        case "failed": self = .failed
        case "preparingSealUpdate": self = .preparingSealUpdate
        default: self = .waiting
        }
    }
}
