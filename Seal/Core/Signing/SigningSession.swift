import Foundation

enum SigningCompletionMode: String, Equatable, Sendable {
    case signAndInstall
}

struct SigningSession: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case running(SigningStage)
        case succeeded(AppRecord)
        case failed(ImportFailure)
    }

    let id: UUID
    let app: AppRecord
    let account: AppleAccountRecord
    let requestedBundleIdentifier: String?
    // var：签名开始时可能为 nil（签名时才申请证书），证书确定后由回调回写，
    // 让进度/失败回看界面显示真实证书而非“未准备”。
    var selectedCertificateSerialNumber: String?
    let completionMode: SigningCompletionMode
    var allowsDroppingExtensions: Bool
    var status: Status
    /// 上传安装阶段的真实进度（0-1），仅 `.pushing` 阶段由安装通道 AFC 上传回传。
    var installProgress: Double?
    /// 当前阶段内部**可数的**完成量（第 i / N 个 bundle ID、已重签 i / N 个可执行文件…）。
    ///
    /// 有了它，环上的每一个百分比都有出处；为 nil 时界面画不确定的转弧、**不给数字**
    /// （2026-09-19 设计讨论：既不用假预估骗人，也不让界面全程静止）。
    ///
    /// 与 `installProgress` 同理，这里带着 `stage` 由消费侧校验 —— 残留上一阶段的
    /// 计数会把进度从新阶段的地板拽回去，所以**不需要**在切阶段时清空它。
    var workUnits: SigningWorkUnits?
    /// 进入 `.installing` 的时刻。installd 安装期间**没有任何进度回报**，
    /// 进度环只能停在 93%（或显示「替换中」）。这里记下起点，让 UI 至少能给出
    /// 「已等待 X 分 Y 秒」——把「没反应」和「正在装」区分开（2026-09-16 真机反馈）。
    var installStartedAt: Date?
    /// 进入**当前阶段**的时刻。
    ///
    /// 进度不再只随阶段跳变：阶段内部按「已过时间」做有上界的估算
    /// （见 `SigningProgressBudget`），所以每个阶段都需要一个起点。
    ///
    /// 起点规则只有一条、且只落在 `InstallStageTimeline.stageStart` 里：
    /// **阶段变化时重置，同一阶段被重复推送时保持**。后者不是优化 ——
    /// `.pushing` / `.installing` 都会被推送不止一次（安装通道的 >1.0 哨兵 +
    /// 签名侧补发），每次都重置会让估算永远停在阶段起点，比不显示更像卡死。
    ///
    /// 为 `nil` 时按「已过 0 秒」处理（回看历史会话、或起点丢失）——
    /// 此时进度停在阶段地板值上，仍然是个**有效**的显示，不会出现负进度或跳变。
    var stageStartedAt: Date?

    init(
        id: UUID = UUID(),
        app: AppRecord,
        account: AppleAccountRecord,
        requestedBundleIdentifier: String? = nil,
        selectedCertificateSerialNumber: String? = nil,
        completionMode: SigningCompletionMode = .signAndInstall,
        allowsDroppingExtensions: Bool = false,
        stageStartedAt: Date? = Date(),
        status: Status
    ) {
        self.id = id
        self.app = app
        self.account = account
        self.requestedBundleIdentifier = requestedBundleIdentifier
        self.selectedCertificateSerialNumber = selectedCertificateSerialNumber
        self.completionMode = completionMode
        self.allowsDroppingExtensions = allowsDroppingExtensions
        // 默认「会话开始 = 当前阶段开始」：会话总是在一个运行中的阶段里被创建的，
        // 起点留空会让进度停在阶段地板值上直到第一次阶段推进。
        self.stageStartedAt = stageStartedAt
        self.status = status
    }
}
