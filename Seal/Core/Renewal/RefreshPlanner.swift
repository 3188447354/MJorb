import Foundation

struct RefreshPlanner: Sendable {
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
            .compactMap { app in
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
                guard let accountID else { return nil }
                return RefreshQueueItem(appID: app.id, accountID: accountID)
            }
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
