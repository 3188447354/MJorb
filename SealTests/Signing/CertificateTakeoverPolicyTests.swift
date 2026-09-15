import Foundation
import Testing
@testable import Seal

struct CertificateTakeoverPolicyTests {
    /// 远端只有 Seal 真实签名者 A 一张、槽位未满：直接创建本机身份，不动 A。
    @Test
    func singleRemoteCertificateWithFreeSlotCreatesLocal() {
        let decision = CertificateTakeoverPolicy.decide(
            remoteSerialNumbers: ["A"],
            localUsableSerialNumbers: [],
            actualSealSignerSerialNumber: "A",
            identityComplete: true
        )
        #expect(decision == .createLocal)
    }

    /// 槽位已满（A + C）：只能请求撤销非 A 的 C，A 永远不在候选里。
    @Test
    func fullSlotsRequestRevocationOfNonSignerCertificatesOnly() {
        let decision = CertificateTakeoverPolicy.decide(
            remoteSerialNumbers: ["A", "C"],
            localUsableSerialNumbers: [],
            actualSealSignerSerialNumber: "A",
            identityComplete: true
        )
        #expect(decision == .requestRevocation(candidateSerialNumbers: ["C"]))
    }

    /// 前导 0 差异不能让真实签名者 A 漏判进撤销候选（坑位 1）。
    @Test
    func signerWithLeadingZeroIsNeverARevocationCandidate() {
        let decision = CertificateTakeoverPolicy.decide(
            remoteSerialNumbers: ["0A", "C"],
            localUsableSerialNumbers: [],
            actualSealSignerSerialNumber: "A",
            identityComplete: true
        )
        #expect(decision == .requestRevocation(candidateSerialNumbers: ["C"]))
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

    /// 槽位满但远端只剩真实签名者自己：没有可安全释放的槽位，阻断。
    @Test
    func fullSlotsWithOnlySignerBlocks() {
        let decision = CertificateTakeoverPolicy.decide(
            remoteSerialNumbers: ["A"],
            localUsableSerialNumbers: [],
            actualSealSignerSerialNumber: "A",
            identityComplete: true,
            maximumCertificates: 1
        )
        if case .blocked = decision {} else {
            Issue.record("只剩 A 一张且槽位满时必须 blocked")
        }
    }
}
