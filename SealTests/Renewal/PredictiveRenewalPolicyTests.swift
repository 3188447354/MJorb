import Foundation
import Testing
@testable import Seal

/// 预测式后台续签（2026-10-03）：只续「窗口内会过期」的。
struct PredictiveRenewalPolicyTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    // MARK: - needsBackgroundRenewal

    @Test
    func includesAppExpiringWithinWindow() {
        let app = makeApp(expiry: now.addingTimeInterval(3600))
        #expect(PredictiveRenewalPolicy.needsBackgroundRenewal(app: app, now: now))
    }

    @Test
    func excludesAppExpiringBeyondWindow() {
        let app = makeApp(expiry: now.addingTimeInterval(3 * 86_400))
        #expect(
            !PredictiveRenewalPolicy.needsBackgroundRenewal(app: app, now: now)
        )
    }

    @Test
    func windowBoundaryIsExclusive() {
        // 恰好 48h 整 ⇒ 不进（`expiry - now < window`，不是 <=）。
        let app = makeApp(expiry: now.addingTimeInterval(PredictiveRenewalPolicy.baseWindow))
        #expect(
            !PredictiveRenewalPolicy.needsBackgroundRenewal(app: app, now: now)
        )
    }

    @Test
    func unknownExpiryFailsOpen() {
        // 过期时间读不到 ⇒ 宁可多续一次，不让它悄悄过期。
        let app = makeApp(expiry: nil)
        #expect(PredictiveRenewalPolicy.needsBackgroundRenewal(app: app, now: now))
    }

    @Test
    func excludesNonInstalledApp() {
        let app = makeApp(expiry: now.addingTimeInterval(3600), state: .imported)
        #expect(
            !PredictiveRenewalPolicy.needsBackgroundRenewal(app: app, now: now)
        )
    }

    @Test
    func alreadyExpiredIsIncluded() {
        let app = makeApp(expiry: now.addingTimeInterval(-3600))
        #expect(PredictiveRenewalPolicy.needsBackgroundRenewal(app: app, now: now))
    }

    // MARK: - backgroundWindow（自适应）

    @Test
    func windowIsBaseWhenNeverRun() {
        #expect(
            PredictiveRenewalPolicy.backgroundWindow(lastRun: nil, now: now)
                == PredictiveRenewalPolicy.baseWindow
        )
    }

    @Test
    func windowIsBaseForDailyTrigger() {
        // 每天跑 ⇒ 间隔 24h + 24h 余量 = 48h = 基准，不扩大。
        let lastRun = now.addingTimeInterval(-24 * 3600)
        #expect(
            PredictiveRenewalPolicy.backgroundWindow(lastRun: lastRun, now: now)
                == PredictiveRenewalPolicy.baseWindow
        )
    }

    @Test
    func windowWidensForWeeklyTrigger() {
        // 每周跑一次 ⇒ 窗口约 8 天 ≈ 全量，避免「上周没到期被跳过、这周已过期」。
        let lastRun = now.addingTimeInterval(-7 * 86_400)
        let window = PredictiveRenewalPolicy.backgroundWindow(lastRun: lastRun, now: now)
        #expect(window == 7 * 86_400 + 24 * 3600)
        #expect(window > 7 * 86_400) // 覆盖免费 profile 的整个 7 天寿命
    }

    // MARK: - RefreshPlanner 接线

    @Test
    func plannerFiltersByPredictiveWindow() {
        let accountID = UUID()
        let urgent = makeApp(name: "Urgent", expiry: now.addingTimeInterval(3600), accountID: accountID)
        let healthy = makeApp(name: "Healthy", expiry: now.addingTimeInterval(6 * 86_400), accountID: accountID)
        let planner = RefreshPlanner()
        let queue = planner.makeQueue(
            apps: [urgent, healthy],
            accounts: [],
            now: now,
            predictiveWindow: PredictiveRenewalPolicy.baseWindow
        )
        #expect(queue.count == 1)
        #expect(queue[0].appID == urgent.id)
    }

    @Test
    func plannerKeepsAllWithoutPredictiveWindow() {
        let accountID = UUID()
        let urgent = makeApp(name: "Urgent", expiry: now.addingTimeInterval(3600), accountID: accountID)
        let healthy = makeApp(name: "Healthy", expiry: now.addingTimeInterval(6 * 86_400), accountID: accountID)
        let planner = RefreshPlanner()
        // nil = 不过滤：手动「续签全部」照旧全量。
        let queue = planner.makeQueue(apps: [urgent, healthy], accounts: [], now: now)
        #expect(queue.count == 2)
    }

    // MARK: - helpers

    private func makeApp(
        name: String = "Demo",
        expiry: Date?,
        accountID: UUID? = UUID(),
        state: AppState = .installed
    ) -> AppRecord {
        AppRecord(
            originalBundleIdentifier: "com.example.\(name.lowercased())",
            name: name,
            version: "1",
            buildNumber: "1",
            size: 1,
            state: state,
            expiryDate: expiry,
            accountID: accountID,
            ipaRelativePath: "Apps/\(UUID().uuidString)/Original.ipa",
            importedAt: Date()
        )
    }
}
