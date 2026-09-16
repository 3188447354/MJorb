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
    mutating func advanceStage(_ stage: SigningStage, at now: Date = Date()) {
        let tick = InstallStageTimeline.tick(entering: stage, currentStage: currentStage)
        installStartedAt = InstallStageTimeline.applied(tick, startedAt: installStartedAt, now: now)
        if stage != .pushing {
            currentInstallProgress = nil
        }
        currentStage = stage
    }
}
