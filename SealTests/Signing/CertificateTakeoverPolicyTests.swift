import Foundation
import Testing
@testable import Seal

struct CertificateTakeoverPolicyTests {
    /// 单槽位空槽（远端无远程证书，|remote| 0 < max 1）：直接创建本机身份 B。
    @Test
    func emptySlotCreatesLocalIdentity() {
        let decision = CertificateTakeoverPolicy.decide(
            remoteSerialNumbers: [],
            localUsableSerialNumbers: [],
            actualSealSignerSerialNumber: "A",
            identityComplete: true
        )
        #expect(decision == .createLocal)
    }

    /// 槽位已满（A + C）：普通证书 C 排在前，真实签名者 A 仍在候选里但**排最后**
    ///（排除 A 会让免费账号永久死锁，见 `CertificateTakeoverPolicy` 文件头注释）。
    @Test
    func fullSlotsPreferNonSignerCertificatesAndKeepTheSignerLast() {
        let decision = CertificateTakeoverPolicy.decide(
            remoteSerialNumbers: ["A", "C"],
            localUsableSerialNumbers: [],
            actualSealSignerSerialNumber: "A",
            identityComplete: true
        )
        #expect(decision == .requestRevocation(candidateSerialNumbers: ["C", "A"]))
    }

    /// 前导 0 差异不能让真实签名者 A 被当成普通证书（坑位 1）：归一化后它仍排最后。
    @Test
    func signerWithLeadingZeroIsStillOrderedLast() {
        let decision = CertificateTakeoverPolicy.decide(
            remoteSerialNumbers: ["0A", "C"],
            localUsableSerialNumbers: [],
            actualSealSignerSerialNumber: "A",
            identityComplete: true
        )
        #expect(decision == .requestRevocation(candidateSerialNumbers: ["C", "0A"]))
    }

    /// 真实签名者不可确认：任何接管动作都禁止，撤销候选必须为空。
    @Test
    func unknownSignerBlocksEveryDecision() {
        let byNilSigner = CertificateTakeoverPolicy.decide(
            remoteSerialNumbers: ["A", "C"],
            localUsableSerialNumbers: [],
            actualSealSignerSerialNumber: nil,
            identityComplete: true
        )
        if case .blocked = byNilSigner {} else {
            Issue.record("签名者未知时必须 blocked")
        }
        let byIncompleteIdentity = CertificateTakeoverPolicy.decide(
            remoteSerialNumbers: ["A", "C"],
            localUsableSerialNumbers: [],
            actualSealSignerSerialNumber: "A",
            identityComplete: false
        )
        if case .blocked = byIncompleteIdentity {} else {
            Issue.record("身份读取不完整时必须 blocked")
        }
    }

    /// 本机已有可用私钥证书 B：直接复用，不创建也不撤销。
    @Test
    func usableLocalCertificateIsReused() {
        let decision = CertificateTakeoverPolicy.decide(
            remoteSerialNumbers: ["A", "B"],
            localUsableSerialNumbers: ["B"],
            actualSealSignerSerialNumber: "A",
            identityComplete: true
        )
        #expect(decision == .reuseLocal(serialNumber: "B"))
    }

    /// 本机证书的归一化命中也要走前导 0 归一（坑位 1）。
    @Test
    func localReuseMatchesAcrossLeadingZeroDifferences() {
        let decision = CertificateTakeoverPolicy.decide(
            remoteSerialNumbers: ["0B"],
            localUsableSerialNumbers: ["B"],
            actualSealSignerSerialNumber: "A",
            identityComplete: true
        )
        #expect(decision == .reuseLocal(serialNumber: "0B"))
    }

    /// 槽位满但远端只剩真实签名者自己：**仍然**把它作为候选提供出来
    ///（`blocked` = 免费账号再也建不出新证书，用户「啥也干不了」）。
    @Test
    func fullSlotsWithOnlySignerStillOffersIt() {
        let decision = CertificateTakeoverPolicy.decide(
            remoteSerialNumbers: ["A"],
            localUsableSerialNumbers: [],
            actualSealSignerSerialNumber: "A",
            identityComplete: true,
            maximumCertificates: 1
        )
        #expect(decision == .requestRevocation(candidateSerialNumbers: ["A"]))
    }
}
