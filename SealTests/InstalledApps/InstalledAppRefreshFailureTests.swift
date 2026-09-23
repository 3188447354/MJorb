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
}
