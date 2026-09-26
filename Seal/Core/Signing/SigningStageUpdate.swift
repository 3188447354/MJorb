import Foundation

/// 「这个阶段属于谁」——**不可变快照**。
///
/// 之所以是快照而不是直接传 `AppRecord`：`AppRecord` 在签名链路里是会被反复改写的
/// `var`（状态、映射后的 Bundle ID、产物快照…），而阶段信号要在 `@Sendable` 闭包里
/// 跨越 actor 边界 —— 直接引用那个 `var` 会变成「捕获可变局部变量」。
/// 主体只需要三样东西，且它们在整条签名链路里**全程不变**，所以取一次就够。
struct SigningStageSubject: Sendable, Equatable {
    /// 该阶段所属 App 的记录 ID。
    let appID: UUID
    /// 该 App 的显示名（仅用于留痕，让日志能说出「这是谁」的阶段）。
    let appName: String
    /// 该 App 是否是 Seal 自身。
    ///
    /// 只有它需要「覆盖安装自己 ⇒ 主动回主屏让 iOS 完成替换」这个副作用。
    let isSeal: Bool

    init(app: AppRecord) {
        self.appID = app.id
        self.appName = app.displayName
        self.isSeal = app.isSeal
    }

    /// 直接给三个字段的构造器 —— 供**纯判据**（`SigningStageAttribution`）的单测使用，
    /// 免得为了造一个主体去建一条 `AppRecord`。
    init(appID: UUID, appName: String, isSeal: Bool) {
        self.appID = appID
        self.appName = appName
        self.isSeal = isSeal
    }
}

/// 一次签名阶段推进 —— **阶段 + 它属于谁**。
///
/// ## 为什么主体必须跟着信号走（2026-09-24 构建 31 真机）
///
/// `SigningCoordinator` 在「用户那个 App 装完之后」还会在**同一条会话**里跑
/// 证书轮换事务（本轮轮换了证书时）：它要重新签名安装所有受旧证书影响的已安装应用，
/// **其中包含 Seal 自己**。于是同一条父会话里会先后推进**两个不同 App** 的阶段。
///
/// 而回主屏的触发判据原先写在 `AppsViewModel.updateSigningStage` 里，用的是
/// **会话主体**（`signingSession?.app.isSeal`）—— 父会话主体是用户那个 App
/// （真机日志里是 LiveContainer）⇒ 判据**恒假** ⇒
/// Seal 的自替换在 installd 阶段一直等旧进程让位，直到 `waitForSelfReplacement`
/// 的 894 秒上限才抛错；用户看到的则是抽屉停在「正在验证安装」。
///
/// ⇒ 主体只能**跟着信号一起传**，不能由调用方去猜父会话是谁。
struct SigningStageUpdate: Sendable, Equatable {
    /// 阶段本身。
    let stage: SigningStage
    /// 这个阶段属于哪个 App —— **不是**会话主体。
    let subject: SigningStageSubject

    init(stage: SigningStage, app: AppRecord) {
        self.stage = stage
        self.subject = SigningStageSubject(app: app)
    }

    init(stage: SigningStage, subject: SigningStageSubject) {
        self.stage = stage
        self.subject = subject
    }
}

/// 一次阶段推进该**归位到谁** —— 纯判据，只有这一处答案。
///
/// ## 为什么需要它（2026-09-26 构建 48 真机）
///
/// `SigningCoordinator` 在父会话里跑证书轮换事务时，会在**同一条会话**里重新签名安装
/// **另一个** App（通常是 Seal 自己），并把子流程的阶段**原样透传**给父会话的 `progress`
/// （见 `SigningStageUpdate` 的说明）。父会话的抽屉于是收到一串**不属于它**的阶段。
///
/// 而 `AppsViewModel.updateSigningStage` 收到后**无条件**写 `signingSession?.status`
/// ⇒ 抽屉在「父会话已经装完、正在验证」之后又跳回签名阶段。
/// 真机日志（构建 48）逐行印证：
///
/// ```text
/// 10:07:44  阶段进入：verifying（Guoguo）        ← 父会话：安装已返回，正在验证
/// 10:07:44  阶段进入：waitingForChannel（Seal）  ← 子流程（证书轮换）开始覆盖父抽屉
/// 10:07:46  阶段进入：preparingBundle（Seal）
/// 10:07:47  阶段进入：preparingCertificate（Seal）
/// 10:07:47  签名并安装成功
/// ```
///
/// 用户看到的就是「**签名到安装步骤后又重签一次**」（原话）。
///
/// ⇒ 判据只能有一处：**阶段属于会话主体才写会话状态**；属于另一个 App 的只留痕，
/// 外加触发 Seal 自替换的「回主屏」（那是「Seal 被覆盖安装」的后果，与会话主体无关）。
enum SigningStageAttribution {
    /// 这次阶段推进该落到哪儿。
    enum Target: Equatable {
        /// 属于会话主体：写进父会话的显示状态（阶段文案 / 进度环 / 计时起点）。
        case session
        /// 属于**子流程里的另一个 App**：只留痕 ＋ 评估 Seal 自替换的「回主屏」，
        /// 绝不碰父会话的显示状态。
        case otherApp(SigningStageSubject)
    }

    /// - Parameters:
    ///   - subject: 信号自带的主体。**缺省 = 会话主体**（历史行为：
    ///     `updateSigningStage(_:subject:)` 的默认参数是 `nil`，旧调用点都不传）。
    ///   - sessionAppID: 当前父会话所属 App 的记录 ID。
    static func target(for subject: SigningStageSubject?, sessionAppID: UUID?) -> Target {
        guard let subject, let sessionAppID, subject.appID != sessionAppID else {
            return .session
        }
        return .otherApp(subject)
    }

    /// 子流程自己的「首次进入安装阶段」闸门。
    ///
    /// 子流程的阶段**不写进父会话** ⇒ 父会话的 `InstallStageTimeline` 不能给它当闸门，
    /// 而 `.installing` 会被推送不止一次（安装通道的 >1.0 哨兵 ＋ 签名侧补发）
    /// ⇒ 不设闸门会排出多个「回主屏」任务（同一个 `.installing` 触发多次）。
    /// 所以子流程单独记一份「上一次阶段」，这里只判「这是不是第一次进安装阶段」。
    ///
    /// - Parameters:
    ///   - stage: 本次推进到的阶段。
    ///   - previous: **同一个**子流程 App 上一次推进到的阶段；`nil` = 这个子流程刚开始。
    static func isFirstInstallEntry(entering stage: SigningStage, previous: SigningStage?) -> Bool {
        stage == .installing && previous != .installing
    }
}
