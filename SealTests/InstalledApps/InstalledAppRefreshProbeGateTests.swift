import Testing
@testable import Seal

@Suite("已安装页设备查询互斥")
struct InstalledAppRefreshProbeGateTests {
    @Test
    func cancelledProbeEntersCooldownInsteadOfLeavingTheGateBusy() async {
        let gate = InstalledAppRefreshProbeGate()

        #expect(await gate.begin() == .ready)
        await gate.finish(timedOut: true)

        #expect(await gate.begin() == .coolingDown)
    }
}
