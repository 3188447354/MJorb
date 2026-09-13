import Foundation
import Testing
@testable import Seal

/// `NotificationPreferences.leadHours` 曾经是个静默 no-op：
/// getter 恒返回固定值、setter 忽略 `newValue`。写了不生效，且看不出来。
@MainActor
struct NotificationPreferencesTests {

    @Test
    func leadHoursFallsBackToTheFixedValue() {
        let preferences = makePreferences()
        #expect(preferences.leadHours == NotificationPreferences.fixedLeadHours)
    }

    @Test
    func leadHoursPersistsWhatIsWritten() {
        let suite = makeSuite()
        NotificationPreferences(defaults: suite).leadHours = 48

        #expect(NotificationPreferences(defaults: suite).leadHours == 48,
                "写入后重建仍应读到写入的值（旧实现会静默丢掉）")
    }

    /// 旧 init 无条件 `set`，每次启动都会抹掉已存的值。
    @Test
    func initializationDoesNotClobberAStoredValue() {
        let suite = makeSuite()
        suite.set(72, forKey: "notifications.expiry.leadHours")

        #expect(NotificationPreferences(defaults: suite).leadHours == 72)
    }

    /// 0 / 负值会让「提前提醒」退化成过期后才提醒，必须回退到默认值而不是照用。
    @Test
    func nonPositiveStoredValueFallsBackToDefault() {
        let suite = makeSuite()
        suite.set(0, forKey: "notifications.expiry.leadHours")
        #expect(NotificationPreferences(defaults: suite).leadHours == NotificationPreferences.fixedLeadHours)

        suite.set(-6, forKey: "notifications.expiry.leadHours")
        #expect(NotificationPreferences(defaults: suite).leadHours == NotificationPreferences.fixedLeadHours)
    }

    @Test
    func writeIsClampedToAtLeastOneHour() {
        let suite = makeSuite()
        NotificationPreferences(defaults: suite).leadHours = 0
        #expect(NotificationPreferences(defaults: suite).leadHours == 1)
    }

    // MARK: - 夹具

    private func makeSuite() -> UserDefaults {
        let name = "NotificationPreferencesTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    private func makePreferences() -> NotificationPreferences {
        NotificationPreferences(defaults: makeSuite())
    }
}
