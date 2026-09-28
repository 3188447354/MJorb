import Foundation
import UserNotifications

@MainActor
final class ExpiryNotificationScheduler {
    private let center: UNUserNotificationCenter
    private let planner: ExpiryNotificationPlanner
    private let identifierPrefix = "com.mjorb.seal.expiry."

    init(
        center: UNUserNotificationCenter = .current(),
        planner: ExpiryNotificationPlanner = ExpiryNotificationPlanner()
    ) {
        self.center = center
        self.planner = planner
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func status(sealEnabled: Bool, schedulingFailure: String? = nil) async -> NotificationScheduleStatus {
        let settings = await center.notificationSettings()
        let authorization: SealNotificationAuthorization
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorization = .allowed
        case .denied:
            authorization = .denied
        case .notDetermined:
            authorization = .notDetermined
        @unknown default:
            authorization = .notDetermined
        }
        let pending = await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(identifierPrefix) }
        let nextDate = pending.compactMap { request in
            (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
        }.min()
        return NotificationScheduleStatus(
            sealEnabled: sealEnabled,
            authorization: authorization,
            soundEnabled: settings.soundSetting == .enabled,
            scheduledCount: pending.count,
            nextReminderDate: nextDate,
            schedulingFailure: schedulingFailure
        )
    }

    func reschedule(
        apps: [AppRecord],
        enabled: Bool,
        leadHours: Int = NotificationPreferences.fixedLeadHours
    ) async throws {
        let existing = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: existing)
        guard enabled else { return }
        let authorization = await authorizationStatus()
        guard authorization == .authorized || authorization == .provisional || authorization == .ephemeral else {
            return
        }

        // ⚠️ 排期**恒定**在到期前 24 小时 —— 由 `ExpiryNotificationPlanner` 的规格钉住
        //（设置页标签写死「提前 24 小时提醒」，`ExpiryNotificationPlannerTests` 断言
        // 「传入 `leadHours = 144` 时 fireDate 仍是到期前 24 小时」）。`reschedule(leadHours:)`
        // 的入参是为将来可配置化预留的，**当前不影响**排期 —— 所以这里不把它传给 planner
        //（传了也是被忽略，反而让读者以为它生效）。要开放配置先改那两处规格。
        for plan in planner.plans(for: apps, now: Date()) {
            let content = UNMutableNotificationContent()
            content.title = "Seal 即将到期"
            let time = Self.timeFormatter.string(from: plan.expiryDate)
            content.body = "明天 \(time) 到期，请及时续签全部。"
            content.sound = .default
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: plan.fireDate
            )
            let request = UNNotificationRequest(
                identifier: identifierPrefix + plan.appID.uuidString,
                content: content,
                trigger: UNCalendarNotificationTrigger(
                    dateMatching: components,
                    repeats: false
                )
            )
            try await center.add(request)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
