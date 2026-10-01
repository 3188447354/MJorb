import Foundation

/// 防止 Apple 门户的旧回包覆盖撤销、换证书或重新同步后的最新状态。
/// SettingsViewModel 运行在 MainActor，此类型只负责判定回包是否仍有效。
struct ApplePortalInventoryRefreshGate: Sendable {
    struct Ticket: Equatable, Sendable {
        let accountID: UUID
        let generation: Int
    }

    private var generations: [UUID: Int] = [:]

    mutating func issueTicket(for accountID: UUID) -> Ticket {
        let generation = (generations[accountID] ?? 0) &+ 1
        generations[accountID] = generation
        return Ticket(accountID: accountID, generation: generation)
    }

    mutating func invalidate(for accountID: UUID) {
        _ = issueTicket(for: accountID)
    }

    func accepts(_ ticket: Ticket) -> Bool {
        generations[ticket.accountID] == ticket.generation
    }
}
