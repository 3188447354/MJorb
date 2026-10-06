import Foundation

/// 续签「规矩」盒子：把散落在全仓的 `if app.isSeal` 特例收拢到策略对象。
///
/// 设计原则：执行引擎（门户操作、描述文件注入、签名、加密）只有一套，Seal 和
/// 第三方共用；不一样的只是「规矩」——准入怎么判、记账怎么写、结算怎么做。
/// 通用链路不再有 `if app.isSeal`，查表 `policy(for:)` 即可。
///
/// UI 层的 isSeal（显示文案、排序）是表现层逻辑，不收进这里。
protocol RenewalPolicy: Sendable {
    /// 生产实时身份。第三方返回 nil（`SelfAppMetadata.current()` 读的是
    /// `Bundle.main`，对第三方调用会得到 Seal 自己的身份，造成假阳性）。
    func liveIdentity(for app: AppRecord) async -> LiveProfileOnlyIdentity?

    /// 准入判定：内部调用 `ProfileOnlyRenewalPolicy.evaluate`。
    func admissionDecision(for app: AppRecord) async -> ProfileOnlyRenewalPolicy.Decision

    /// 签名完成后的产物状态。两阶段提交下统一返回 `.awaitingVerification`，
    /// 由安装校验或启动结算推进到 `.installed`。
    func statusAfterSigning(originalState: AppState) -> SignedArtifactStatus

    /// 是否允许弹「撤销并继续签名」。Seal 永远不允许
    /// （撤销运行中 Seal 正在用的证书会导致变砖，2026-09-14 真机）。
    var allowsRevocationPrompt: Bool { get }

    /// 是否豁免 Bundle ID 冲突去重。Seal 自身更新是覆盖安装，豁免。
    var exemptsBundleIDConflict: Bool { get }

    /// 是否需要贯穿整条链路的后台任务。Seal 自续签需要（防锁屏挂起）。
    var needsExtendedBackgroundTask: Bool { get }
}

/// 第三方应用的通用规矩：全部走默认值。
struct DefaultRenewalPolicy: RenewalPolicy, Sendable {
    func liveIdentity(for app: AppRecord) async -> LiveProfileOnlyIdentity? {
        nil
    }

    func admissionDecision(for app: AppRecord) async -> ProfileOnlyRenewalPolicy.Decision {
        ProfileOnlyRenewalPolicy.evaluate(app: app)
    }

    func statusAfterSigning(originalState: AppState) -> SignedArtifactStatus {
        guard originalState == .installed else { return .available }
        return .awaitingVerification
    }

    var allowsRevocationPrompt: Bool { true }
    var exemptsBundleIDConflict: Bool { false }
    var needsExtendedBackgroundTask: Bool { false }
}

/// Seal 自身的规矩：自管理应用的特殊 lifecycle 收拢于此。
struct SelfManagedRenewalPolicy: RenewalPolicy, Sendable {
    func liveIdentity(for app: AppRecord) async -> LiveProfileOnlyIdentity? {
        let metadata = await MainActor.run { SelfAppMetadata.current() }
        return ProfileOnlyRenewalPolicy.liveIdentity(
            installedIdentity: metadata?.installedIdentity,
            runningVersion: metadata?.version,
            app: app
        )
    }

    func admissionDecision(for app: AppRecord) async -> ProfileOnlyRenewalPolicy.Decision {
        let identity = await liveIdentity(for: app)
        return ProfileOnlyRenewalPolicy.evaluate(app: app, liveIdentity: identity)
    }

    func statusAfterSigning(originalState: AppState) -> SignedArtifactStatus {
        // 两阶段提交：签名阶段统一写 .awaitingVerification，不再乐观写 .installed。
        // Seal 自替换场景由新进程的 SelfAppRegistrar 做两阶段确认后推进到 .installed。
        // 旧注释"签名阶段是安装前唯一的写入机会"已过期——现在写的是 pending，不是顶层。
        .awaitingVerification
    }

    var allowsRevocationPrompt: Bool { false }
    var exemptsBundleIDConflict: Bool { true }
    var needsExtendedBackgroundTask: Bool { true }
}

/// 查表：Seal 用自管理规矩，其他用通用规矩。
func policy(for app: AppRecord) -> any RenewalPolicy {
    app.isSeal ? SelfManagedRenewalPolicy() : DefaultRenewalPolicy()
}
