import Foundation

enum SelfReplacementReconcileAction: Equatable, Sendable {
    case none
    case awaitNextLaunch
    case settle
    case closeAsNotInstalled
    case requireRecovery(reason: String)
}

enum SelfReplacementPolicy {
    struct Input: Equatable, Sendable {
        let candidateMatches: Bool
        let oldMatches: Bool
        let readable: Bool
    }

    static func reconcile(_ input: Input) -> SelfReplacementReconcileAction {
        guard input.readable else {
            return .requireRecovery(reason: "无法完整读取当前 Seal 主程序和扩展身份")
        }
        if input.candidateMatches { return .settle }
        if input.oldMatches { return .closeAsNotInstalled }
        return .requireRecovery(reason: "当前 Seal 与安装前身份、候选身份都不一致")
    }

    static func reconcile(
        transaction: SelfReplacementTransaction,
        running: InstalledIdentity,
        currentProcessID: UUID,
        preparedProcessID: UUID,
        withinReplacementGrace: Bool = false
    ) -> SelfReplacementReconcileAction {
        guard transaction.phase != .confirmed else { return .none }
        guard currentProcessID != preparedProcessID else { return .awaitNextLaunch }
        guard running.isComplete else {
            return .requireRecovery(reason: "无法完整读取当前 Seal 主程序和扩展身份")
        }
        if transaction.candidate.matches(running) { return .settle }
        if running == transaction.installedBefore {
            // ⚠️ 「仍在安装前身份」有**两种**成因，必须分开（2026-09-25，构建 38 真机）：
            //   ① 安装**真的失败了** ⇒ 该按「未安装」关闭事务（终态）；
            //   ② 传输刚返回、installd 还在**替换进行中** ⇒ 此刻读到旧包完全正常。
            // 把 ② 当 ① 处理是**不可恢复**的：`closeAsNotInstalled` 会写 `settledAt`，
            // 之后每次启动都不再对账，而记录已经在签名阶段被乐观推进成新 profile
            // ⇒ 记录与设备现实永久错位（维护作业随后会删掉正在用的那份 profile）。
            //
            // 为什么不能只靠耗时区分：`install()` 返回只代表「传输完成 + installd 接受
            // 命令」，实际替换是异步的、不可观测。真机上 01:46:19 上传完成、01:46:30 判
            // 失败（11 秒），而同一台设备另一次 8 秒就结算成功了 ⇒ 耗时没有判别力。
            // ⇒ 用一个**明确的宽限期**表达「还没装完」：窗口内保留事务（下次启动再判），
            //   窗口过了才按未安装关闭。
            return withinReplacementGrace ? .awaitNextLaunch : .closeAsNotInstalled
        }
        return .requireRecovery(reason: "当前 Seal 与安装前身份、候选身份都不一致")
    }

    /// 比较「正在运行的 Seal」与「刚签名出的候选 Seal」的 bundle 组成是否一致。
    /// 一致返回 nil（可继续自续签）；不一致返回具体失败原因：
    /// - 旧版含内置扩展（如 TunnelProv）→ 新版无扩展 属迁移形态，必须电脑安装助手覆盖；
    /// - 其余组合仍是通用 bundleShapeChanged。
    static func shapeMismatch(
        running: InstalledIdentity,
        candidate: CandidateIdentity
    ) -> SelfReplacementFailure? {
        let runningIDs = running.targets.map(\.bundleIdentifier).sorted()
        let candidateIDs = candidate.targets.map(\.bundleIdentifier).sorted()
        guard runningIDs != candidateIDs else { return nil }
        let runningHasExtension = running.targets.contains { $0.kind == .appExtension }
        let candidateHasExtension = candidate.targets.contains { $0.kind == .appExtension }
        if runningHasExtension && !candidateHasExtension {
            return .extensionRemovalRequiresComputerInstall
        }
        return .bundleShapeChanged
    }
}
