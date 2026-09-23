import Testing
@testable import Seal

@Suite("已安装页设备查询预算")
struct InstalledAppRefreshProbePolicyTests {
    @Test
    func refreshProbeFailsFastWithoutBorrowingInstallationBudget() {
        #expect(InstalledAppRefreshProbePolicy.timeoutSeconds == 2)
        #expect(InstalledAppRefreshProbePolicy.timeoutCooldownSeconds > BlockingCall.queryTimeoutSeconds)
    }
}
