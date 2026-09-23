import Testing
@testable import Seal

@Suite("已安装页刷新策略")
struct InstalledAppRefreshPolicyTests {
    @Test
    func reloadsOnceAfterAnySuccessfulReconciliationMutation() {
        #expect(InstalledAppRefreshPolicy.requiresReload(after: [false, true, false]))
    }

    @Test
    func skipsExtraReloadWhenReconciliationChangedNothing() {
        #expect(InstalledAppRefreshPolicy.requiresReload(after: [false, false]) == false)
    }
}
