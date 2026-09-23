import Foundation
import Testing
@testable import Seal

@Suite("已安装页设备核验诊断")
struct InstalledAppRefreshFailureTests {
    @Test
    func diagnosticKeepsTheTimeoutReason() {
        let error = NSError(
            domain: "SealInstalledAppDeviceVerifier",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Device probe timed out"]
        )

        #expect(InstalledAppRefreshFailure.diagnostic(for: error) ==
            "设备应用查询未完成 [SealInstalledAppDeviceVerifier 2] Device probe timed out")
    }

    @Test
    func onlyActionableRefreshFailuresAreLogged() {
        let timeout = NSError(
            domain: "SealInstalledAppDeviceVerifier",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Device probe timed out"]
        )
        let coolingDown = NSError(
            domain: "SealInstalledAppDeviceVerifier",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Device probe is cooling down after a timeout"]
        )

        #expect(InstalledAppRefreshFailure.shouldLogDiagnostic(for: timeout))
        #expect(InstalledAppRefreshFailure.shouldLogDiagnostic(for: coolingDown) == false)
        #expect(InstalledAppRefreshFailure.shouldLogDiagnostic(for: CancellationError()) == false)
    }
}
