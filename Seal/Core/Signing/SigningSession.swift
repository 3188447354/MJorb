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
    /// 进入 `.installing` 的时刻。installd 安装期间**没有任何进度回报**，
    /// 进度环只能停在 93%（或显示「替换中」）。这里记下起点，让 UI 至少能给出
    /// 「已等待 X 分 Y 秒」——把「没反应」和「正在装」区分开（2026-09-16 真机反馈）。
    var installStartedAt: Date?

    init(
        id: UUID = UUID(),
        app: AppRecord,
        account: AppleAccountRecord,
        requestedBundleIdentifier: String? = nil,
        selectedCertificateSerialNumber: String? = nil,
        completionMode: SigningCompletionMode = .signAndInstall,
        allowsDroppingExtensions: Bool = false,
        status: Status
    ) {
        self.id = id
        self.app = app
        self.account = account
        self.requestedBundleIdentifier = requestedBundleIdentifier
        self.selectedCertificateSerialNumber = selectedCertificateSerialNumber
        self.completionMode = completionMode
        self.allowsDroppingExtensions = allowsDroppingExtensions
        self.status = status
    }
}
