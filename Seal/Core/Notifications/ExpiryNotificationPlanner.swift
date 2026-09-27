import Foundation

struct ExpiryNotificationPlan: Equatable, Sendable {
    let appID: UUID
    let appName: String
    let isSeal: Bool
    let fireDate: Date
    let expiryDate: Date
}

struct ExpiryNotificationPlanner: Sendable {
    func plans(
        for apps: [AppRecord],
        leadHours: Int = 24,
        now: Date = Date()
    ) -> [ExpiryNotificationPlan] {
        apps.compactMap { app in
            guard app.isSeal,
                  app.belongsInInstalledList,
                  let expiryDate = app.expiryDate,
                  expiryDate > now else { return nil }
            // 用传入的 `leadHours`：此前硬编码 24 ⇒ 参数是**死的**，调用方传别的值会被静默忽略。
            let requestedFireDate = expiryDate.addingTimeInterval(TimeInterval(-leadHours * 3_600))
            guard requestedFireDate > now else { return nil }
            return ExpiryNotificationPlan(
                appID: app.id,
                appName: app.name,
                isSeal: app.isSeal,
                fireDate: requestedFireDate,
                expiryDate: expiryDate
            )
        }
        .sorted { lhs, rhs in
            if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
            return lhs.appName.localizedStandardCompare(rhs.appName) == .orderedAscending
        }
    }
}
