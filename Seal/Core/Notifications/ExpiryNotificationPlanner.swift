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
            // 🔴 提醒**恒定**排在到期前 **24 小时**（2026-09-28 复核后**刻意保留**，勿再「顺手修」）：
            // 这是**规格**，有两处钉住它 ——
            //   ① 设置页标签写死「提前 24 小时提醒」（`SettingsRootView`，不是可配置项）；
            //   ② `ExpiryNotificationPlannerTests.schedulesSealBeforeExpiration` 明确断言
            //      「即使传入 `leadHours = 144`，`fireDate` 仍是到期前 24 小时」。
            // `leadHours` 只是**为将来可配置化预留的入参**（`NotificationPreferences.leadHours`
            // 的真实读写由 `NotificationPreferencesTests` 覆盖），当前**不影响**排期。
            // ⚠️ 曾试过改成 `-leadHours * 3600`，会让上面那条测试 `plans.count` 变 0 并
            // 崩在 `plans[0]`（CI `swift-regression` 红）。要真开放配置，**先改那两处规格**。
            let requestedFireDate = expiryDate.addingTimeInterval(-24 * 3_600)
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
