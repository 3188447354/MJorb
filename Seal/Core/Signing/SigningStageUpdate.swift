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
