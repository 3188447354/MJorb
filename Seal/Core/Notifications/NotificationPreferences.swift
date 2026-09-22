import Foundation

@MainActor
final class NotificationPreferences {
    private enum Key {
        static let enabled = "notifications.expiry.enabled"
        static let leadHours = "notifications.expiry.leadHours"
    }

    static let fixedLeadHours = 24
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 用 register(defaults:) 而不是 set(_:forKey:)：后者每次启动都会无条件覆盖
        // 已存的值，等于「用户（或将来）写进去的偏好在下次启动被抹掉」。
        defaults.register(defaults: [Key.leadHours: Self.fixedLeadHours])
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// 过期提醒的提前量（小时）。
    ///
    /// 旧实现是个**静默 no-op**：getter 恒返回 `fixedLeadHours`、setter 忽略 `newValue`
    /// 却照写 UserDefaults。它看起来是个可写偏好项，实际写了也不生效 ——
    /// 一旦以后真的开放配置（调用链 `reschedule(leadHours:)` / `ExpiryNotificationPlanner`
    /// 都已经支持传值），这里会悄悄吞掉写入，而且很难查。
    /// 现在真实读写 UserDefaults，默认值仍是 `fixedLeadHours`，当前行为不变。
    var leadHours: Int {
        get {
            let stored = defaults.integer(forKey: Key.leadHours)
            return stored > 0 ? stored : Self.fixedLeadHours
        }
        set { defaults.set(max(1, newValue), forKey: Key.leadHours) }
    }
}
