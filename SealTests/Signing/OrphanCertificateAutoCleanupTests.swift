import Foundation
import Testing
@testable import Seal

struct OrphanCertificateAutoCleanupTests {
    private func failure(_ code: String) -> ImportFailure {
        ImportFailure(title: "t", reason: "r", recovery: "r", code: code)
    }

    /// 只有这几类阻断才允许触发自动清理：证书名额满（204a 文案归类 + 204b
    /// isCertificateLimitError 归类，两条平行路径缺一不可——2026-09-14 真机
    /// 漏挂 204b 导致无感清理完全不触发）/ 本机无私钥 / 绑定已失效。
    @Test
    func orphanBlockingCodesTriggerAutoCleanup() {
        #expect(SigningCoordinator.isOrphanCertificateBlocking(failure("SEAL-CERT-204a")))
        #expect(SigningCoordinator.isOrphanCertificateBlocking(failure("SEAL-CERT-204b")))
        #expect(SigningCoordinator.isOrphanCertificateBlocking(failure("SEAL-CERT-204c")))
        #expect(SigningCoordinator.isOrphanCertificateBlocking(failure("SEAL-CERT-204d")))
    }

    /// 其余任何错误（网络、会话过期、App ID 上限、安装失败……）一律不触发：
    /// 自动撤销是不可逆远端操作，触发面必须最小化。
    @Test
    func unrelatedFailuresNeverTriggerAutoCleanup() {
        for code in [
            "SEAL-NET-102", "SEAL-AUTH-107", "SEAL-AUTH-105g", "SEAL-APPID-301",
            "SEAL-APPID-304", "SEAL-CERT-203", "SEAL-CERT-205", "SEAL-CERT-217",
            "SEAL-PROFILE-313", "SEAL-INSTALL-702l", "SEAL-SIGN-405", "SEAL-SIGN-503",
            "SEAL-CERT-220", "SEAL-CERT-221"
        ] {
            #expect(SigningCoordinator.isOrphanCertificateBlocking(failure(code)) == false)
        }
    }
}
