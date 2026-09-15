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
}
