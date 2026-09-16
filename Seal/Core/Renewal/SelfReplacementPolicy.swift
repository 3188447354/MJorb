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
        preparedProcessID: UUID
    ) -> SelfReplacementReconcileAction {
        guard transaction.phase != .confirmed else { return .none }
        guard currentProcessID != preparedProcessID else { return .awaitNextLaunch }
        guard running.isComplete else {
            return .requireRecovery(reason: "无法完整读取当前 Seal 主程序和扩展身份")
        }
        if transaction.candidate.matches(running) { return .settle }
        if running == transaction.installedBefore { return .closeAsNotInstalled }
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
