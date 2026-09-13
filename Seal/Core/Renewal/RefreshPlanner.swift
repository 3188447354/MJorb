import Foundation

struct RefreshPlanner: Sendable {
    /// 「没进本轮」的原因必须是可执行的引导，不能只说「跳过」。
    static let missingAccountReason = "没有可用于续签的 Apple 账号：请到「我的」添加并完成验证，或先为该应用指定账号"

    func makeQueue(
        apps: [AppRecord],
        fallbackAccountID: UUID? = nil,
        accounts: [AppleAccountRecord] = [],
        now: Date = Date()
    ) -> [RefreshQueueItem] {
        apps
            .filter { $0.belongsInInstalledList }
            .sorted { lhs, rhs in
                priority(for: lhs, now: now) < priority(for: rhs, now: now)
            }
            .map { app -> RefreshQueueItem in
                var accountID = app.accountID ?? fallbackAccountID
                // Match Seal's installed Team before considering a global default account.
                if app.isSeal, let teamID = app.signingTeamID, teamID.isEmpty == false {
                    let matchingAccounts = accounts.filter {
                        $0.teamID.caseInsensitiveCompare(teamID) == .orderedSame
                            && AccountAvailabilityPolicy.isSelectable($0)
                    }
                    accountID = matchingAccounts.first(where: { $0.id == app.accountID })?.id
                        ?? matchingAccounts.first?.id
                        ?? app.accountID
                }
                guard let accountID else {
                    // 关键：**不要静默丢弃**。旧实现在这里 `return nil`，
                    // 于是「批量续签完成」看起来一切正常，实际有应用根本没被处理，
                    // 用户既看不到它、也不知道为什么。改为显式 requiresAction，
                    // 让它在队列与结果计数里都留下痕迹。
                    return RefreshQueueItem(
                        appID: app.id,
                        accountID: nil,
                        state: .requiresAction,
                        requiresActionReason: Self.missingAccountReason
                    )
                }
                return RefreshQueueItem(appID: app.id, accountID: accountID)
            }
    }

    /// 本轮不会执行、需要用户先处理的项。
    static func needsAction(in queue: [RefreshQueueItem]) -> [RefreshQueueItem] {
        queue.filter { $0.state == .requiresAction }
    }

    private func priority(for app: AppRecord, now: Date) -> Priority {
        let expiry = app.expiryDate ?? .distantPast
        let isUrgent = expiry.timeIntervalSince(now) < 86_400
        return Priority(
            group: app.isSeal ? 2 : (isUrgent ? 0 : 1),
            expiry: expiry,
            importedAt: app.importedAt
        )
    }
}

private struct Priority: Comparable {
    let group: Int
    let expiry: Date
    let importedAt: Date

    static func < (lhs: Priority, rhs: Priority) -> Bool {
        if lhs.group != rhs.group { return lhs.group < rhs.group }
        if lhs.expiry != rhs.expiry { return lhs.expiry < rhs.expiry }
        return lhs.importedAt < rhs.importedAt
    }
}
