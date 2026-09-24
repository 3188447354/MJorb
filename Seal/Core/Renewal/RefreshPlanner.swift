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
                // 与单项续签、`beginSigning` **共用同一份判据**（`RenewalAccountResolver`）：
                // 记录里的 `accountID` 可能是**悬空引用**（删过 Apple ID 再重新添加之后），
                // 旧写法 `app.accountID ?? fallbackAccountID` 会把它原样带进队列 ⇒
                // 批量续签里这个应用必然失败。旧实现还**只给 `isSeal` 开了同 Team 匹配的口子**，
                // 而判据与风险对所有应用完全相同。
                let resolution = RenewalAccountResolver.resolve(
                    recordedAccountID: app.accountID,
                    recordedTeamID: app.signingTeamID,
                    accounts: accounts,
                    fallbackAccountID: fallbackAccountID
                )
                guard case .resolved(let accountID) = resolution else {
                    // 关键：**不要静默丢弃**。旧实现在这里 `return nil`，
                    // 于是「批量续签完成」看起来一切正常，实际有应用根本没被处理，
                    // 用户既看不到它、也不知道为什么。改为显式 requiresAction，
                    // 让它在队列与结果计数里都留下痕迹。
                    // ⚠️ 原因必须**分情况**：几种「没账号」的下一步动作完全不同，
                    // 共用一个文案等于没说。
                    return RefreshQueueItem(
                        appID: app.id,
                        accountID: nil,
                        state: .requiresAction,
                        requiresActionReason: Self.reason(for: resolution, app: app)
                    )
                }
                return RefreshQueueItem(appID: app.id, accountID: accountID)
            }
    }

    /// `requiresAction` 的原因文案 —— **一种原因一条文案**，都要能直接照着做。
    static func reason(
        for resolution: RenewalAccountResolver.Resolution,
        app: AppRecord
    ) -> String {
        switch resolution {
        case .resolved:
            // 解析成功不会走到这里；留一条自明的话，避免将来被改错时出现空文案。
            return missingAccountReason
        case .recordedAccountNeedsVerification:
            return "\(app.name) 记录的签名账号需要重新验证：请到「我的」重新验证该 Apple ID，或为这个应用指定其他账号"
        case .recordedAccountMissing(let teamID):
            let team = (teamID?.isEmpty == false ? teamID! : "未知")
            return "\(app.name) 原来由 Team \(team) 的 Apple ID 签名，该账号已删除且没有同 Team 的可用账号：请到「我的」添加同 Team 的 Apple ID，或为这个应用指定账号"
        case .noSelectableAccount:
            return missingAccountReason
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
