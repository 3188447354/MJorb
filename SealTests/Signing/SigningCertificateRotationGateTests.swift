import Foundation
import Testing
@testable import Seal

/// 证书轮换闸门的回归钉（2026-09-26，构建 46 真机）。
///
/// 现象：签第三方应用时，自动轮换把**运行中 Seal 正在用**的证书撤掉了
/// （日志：`证书轮换：撤销 …442EB5AF，原因=无本机私钥，运行中Seal=是`），
/// 随后 Seal 被迫自替换重装、`SEAL-SELF-109` 中止，用户看到「签名续签链路被弄坏了」。
struct SigningCertificateRotationGateTests {

    @Test
    func runningSealCertificateIsExcludedWhenSigningThirdPartyApp() {
        let candidates = [
            candidate(serial: "AAAA", reason: .missingPrivateKey, isRunningSeal: false),
            candidate(serial: "BBBB", reason: .missingPrivateKey, isRunningSeal: true)
        ]

        let filtered = SigningCertificateRotationGate.candidatesExcludingRunningSealCertificate(
            candidates: candidates,
            isSigningSeal: false
        )

        #expect(filtered.map(\.serialNumber) == ["AAAA"])
    }

    @Test
    func runningSealCertificateStaysWhenSigningSealItself() {
        // Seal 自身续签 / 重签时撤自己的证书是本事务设计内的一步
        //（末尾会以新证书重新安装）—— 不能连这条路一起堵死。
        let candidates = [
            candidate(serial: "AAAA", reason: .missingPrivateKey, isRunningSeal: false),
            candidate(serial: "BBBB", reason: .missingPrivateKey, isRunningSeal: true)
        ]

        let filtered = SigningCertificateRotationGate.candidatesExcludingRunningSealCertificate(
            candidates: candidates,
            isSigningSeal: true
        )

        #expect(filtered.map(\.serialNumber) == ["AAAA", "BBBB"])
    }

    @Test
    func emptyResultWhenTheOnlyCandidateIsTheRunningSealCertificate() {
        // 这一支必须能被调用方识别成「无可轮换」⇒ 抛回 `SEAL-CERT-204b`，
        // 而不是静默撤掉 Seal 的证书（那是变砖路径）。
        let candidates = [
            candidate(serial: "BBBB", reason: .missingPrivateKey, isRunningSeal: true)
        ]

        let filtered = SigningCertificateRotationGate.candidatesExcludingRunningSealCertificate(
            candidates: candidates,
            isSigningSeal: false
        )

        #expect(filtered.isEmpty)
    }

    @Test
    func nonSealCandidatesAreUntouched() {
        let candidates = [
            candidate(serial: "AAAA", reason: .missingPrivateKey, isRunningSeal: false),
            candidate(serial: "CCCC", reason: .insufficientLifetime, isRunningSeal: false),
            candidate(serial: "DDDD", reason: .invalidValidity, isRunningSeal: false)
        ]

        let filtered = SigningCertificateRotationGate.candidatesExcludingRunningSealCertificate(
            candidates: candidates,
            isSigningSeal: false
        )

        #expect(filtered.map(\.serialNumber) == ["AAAA", "CCCC", "DDDD"])
        // 顺序也要保住：撤销顺序决定「失效窗口」的长短，Seal 的证书本来排在最后。
        #expect(filtered == candidates)
    }

    // MARK: - Fixtures

    private func candidate(
        serial: String,
        reason: SigningCertificateRotationReason,
        isRunningSeal: Bool
    ) -> SigningCertificateRotationCandidate {
        SigningCertificateRotationCandidate(
            serialNumber: serial,
            reason: reason,
            isRunningSealCertificate: isRunningSeal
        )
    }
}
