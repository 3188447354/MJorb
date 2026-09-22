import Foundation
import Testing
@testable import Seal

struct CertificateCleanupPolicyTests {
    private func makeCertificate(_ serial: String) -> ApplePortalCertificateSnapshot {
        ApplePortalCertificateSnapshot(
            serialNumber: serial,
            machineName: "Mac-\(serial)",
            machineIdentifier: nil,
            hasLocalPrivateKey: false,
            expirationDate: Date(timeIntervalSince1970: 2_000_000_000)
        )
    }

    private func makeApp(name: String, serial: String?, state: AppState = .installed) -> AppRecord {
        AppRecord(
            originalBundleIdentifier: "com.example.\(name)",
            name: name,
            version: "1.0",
            buildNumber: "1",
            size: 1024,
            state: state,
            certificateSerialNumber: serial,
            ipaRelativePath: "\(name).ipa",
            importedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// 不与任何用例证书冲突的真实签名者，让既有用例聚焦自身语义。
    private let unrelatedSealSigner = "SEAL9999"

    // MARK: - makePlan（自动清理须保护所有已知引用）

    /// 全部无钥匙、无关联 App 的证书一律可撤。
    @Test
    func orphanCertificatesWithoutKeyAreRevocable() {
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("AA11"), makeCertificate("0BB22")],
            apps: [],
            localUsableSerials: [],
            deviceReferencedSerials: [],
            sealActualSignerSerialNumber: unrelatedSealSigner,
            identityConfidence: .complete
        )
        #expect(plan.revocable.map(\.serialNumber) == ["AA11", "0BB22"])
        #expect(plan.kept.isEmpty)
        #expect(plan.deviceVerified)
        #expect(plan.blockedReason == nil)
    }

    /// 本机仍存 P12 的证书（含历史 map 里的）绝不能撤：它还能无感复用。
    @Test
    func certificateWithLocalPrivateKeyIsKept() {
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("AA11"), makeCertificate("BB22")],
            apps: [],
            localUsableSerials: ["BB22"],
            deviceReferencedSerials: [],
            sealActualSignerSerialNumber: unrelatedSealSigner,
            identityConfidence: .complete
        )
        #expect(plan.revocable.map(\.serialNumber) == ["AA11"])
        #expect(plan.kept.map(\.serialNumber) == ["BB22"])
    }

    /// 本机没有私钥也不能撤销其他已安装应用正在使用的证书。
    @Test
    func certificateUsedByInstalledAppIsKeptWithoutLocalKey() {
        let apps = [makeApp(name: "微信", serial: "0AA11")]
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("AA11"), makeCertificate("BB22")],
            apps: apps,
            localUsableSerials: [],
            deviceReferencedSerials: [],
            sealActualSignerSerialNumber: unrelatedSealSigner,
            identityConfidence: .complete
        )
        #expect(plan.revocable.map(\.serialNumber) == ["BB22"])
        #expect(plan.kept.map(\.serialNumber) == ["AA11"])
    }

    /// 设备 profile 可能属于其他签名工具，引用同样需要保护。
    @Test
    func certificateReferencedByDeviceProfileIsKeptWithoutLocalKey() {
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("AA11"), makeCertificate("BB22")],
            apps: [],
            localUsableSerials: [],
            deviceReferencedSerials: ["AA11"],
            sealActualSignerSerialNumber: unrelatedSealSigner,
            identityConfidence: .complete
        )
        #expect(plan.revocable.map(\.serialNumber) == ["BB22"])
        #expect(plan.kept.map(\.serialNumber) == ["AA11"])
    }

    /// 设备核验不可用时不能将未知误判为无人使用。
    @Test
    func unverifiedDeviceMarksPlanAsNotDeviceVerified() {
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("AA11")],
            apps: [],
            localUsableSerials: [],
            deviceReferencedSerials: nil,
            sealActualSignerSerialNumber: unrelatedSealSigner,
            identityConfidence: .complete
        )
        #expect(plan.revocable.isEmpty)
        #expect(plan.deviceVerified == false)
    }

    /// 归一化：前导 0 差异不能让「有私钥」的证书误入候选（坑位 1）。
    @Test
    func leadingZeroDifferencesDoNotLeakIntoRevocable() {
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("0AA11"), makeCertificate("BB22")],
            apps: [],
            localUsableSerials: ["AA11"],
            deviceReferencedSerials: ["0BB22"],
            sealActualSignerSerialNumber: unrelatedSealSigner,
            identityConfidence: .complete
        )
        #expect(plan.revocable.isEmpty)
        #expect(plan.kept.map(\.serialNumber) == ["0AA11", "BB22"])
    }

    // MARK: - 真实签名者保护（只相信 CMS 签名者，不相信描述文件授权列表）

    /// 描述文件授权了 A 和 C 两张证书时，真实签名者 A 仍必须保留。
    @Test
    func actualSealSignerIsProtectedWhenProfileAuthorizesTwoCertificates() {
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("A"), makeCertificate("C")],
            apps: [],
            localUsableSerials: [],
            deviceReferencedSerials: ["A", "C"],
            sealActualSignerSerialNumber: "A",
            identityConfidence: .complete
        )
        #expect(plan.revocable.contains(where: { $0.serialNumber == "A" }) == false)
    }

    /// 真实签名者读不出来时，自动撤销全部关闭：任何一张都可能是 Seal 的命。
    @Test
    func unknownSealSignerDisablesAllAutomaticRevocation() {
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("A"), makeCertificate("C")],
            apps: [],
            localUsableSerials: [],
            deviceReferencedSerials: nil,
            sealActualSignerSerialNumber: nil,
            identityConfidence: .unreadable
        )
        #expect(plan.revocable.isEmpty)
        #expect(plan.blockedReason != nil)
    }

    /// 身份读取不完整（有 readErrors / 缺 target）等同于未知签名者：一律阻断。
    @Test
    func incompleteIdentityDisablesAllAutomaticRevocation() {
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("A")],
            apps: [],
            localUsableSerials: [],
            deviceReferencedSerials: [],
            sealActualSignerSerialNumber: "A",
            identityConfidence: .unreadable
        )
        #expect(plan.revocable.isEmpty)
        #expect(plan.blockedReason != nil)
    }

    /// 描述文件授权但不是真实签名者的证书，不再享受 Seal 自保护：
    /// 没有其他引用时可以被撤销（「只相信真实签名者」的语义变化）。
    @Test
    func profileAuthorizedButNotActualSignerIsNotSealProtected() {
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("AA11"), makeCertificate("CC22")],
            apps: [],
            localUsableSerials: [],
            deviceReferencedSerials: [],
            sealActualSignerSerialNumber: "AA11",
            identityConfidence: .complete
        )
        #expect(plan.revocable.map(\.serialNumber) == ["CC22"])
        #expect(plan.kept.map(\.serialNumber) == ["AA11"])
        #expect(plan.protectedSealWithoutKeyCount == 1)
    }

    /// Seal 自保护：真实签名者即使本机无私钥也必须保留。
    /// 撤了 Seal 下次启动就「不再可用」，直接变砖。
    @Test
    func actualSealSignerIsKeptEvenWithoutLocalKey() {
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("AA11"), makeCertificate("BB22")],
            apps: [],
            localUsableSerials: [],
            deviceReferencedSerials: [],
            sealActualSignerSerialNumber: "AA11",
            identityConfidence: .complete
        )
        // AA11 是 Seal 真实签名者 → 即使无私钥也 kept；BB22 无私钥且非签名者 → revocable
        #expect(plan.revocable.map(\.serialNumber) == ["BB22"])
        #expect(plan.kept.map(\.serialNumber) == ["AA11"])
        #expect(plan.localPrivateKeyCount == 0)
        #expect(plan.protectedSealWithoutKeyCount == 1)
    }

    /// Seal 自保护：序列号归一化（前导 0 差异）不能让真实签名者误入可撤（坑位 1）。
    @Test
    func actualSealSignerLeadingZeroIsNormalized() {
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("0AA11"), makeCertificate("BB22")],
            apps: [],
            localUsableSerials: [],
            deviceReferencedSerials: [],
            sealActualSignerSerialNumber: "AA11",
            identityConfidence: .complete
        )
        // 0AA11 归一化后等于真实签名者 AA11 → 保留；BB22 可撤
        #expect(plan.revocable.map(\.serialNumber) == ["BB22"])
        #expect(plan.kept.map(\.serialNumber) == ["0AA11"])
    }

    @Test
    func unknownInstalledIdentityPreventsAutomaticRevocation() {
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("AA11")],
            apps: [makeApp(name: "Unknown", serial: nil)], localUsableSerials: [],
            deviceReferencedSerials: [],
            sealActualSignerSerialNumber: unrelatedSealSigner,
            identityConfidence: .complete
        )
        #expect(plan.revocable.isEmpty)
    }

    // MARK: - sacrificeCandidates（用户确认后的全撤候选）

    /// 用户确认后的「全撤」候选：所有无私钥证书，与 makePlan 新策略行为一致。
    @Test
    func sacrificeCandidatesIncludeAllKeylessCertificates() {
        let candidates = CertificateCleanupPolicy.sacrificeCandidates(
            certificates: [makeCertificate("AA11"), makeCertificate("BB22")],
            localUsableSerials: []
        )
        #expect(candidates.map(\.serialNumber) == ["AA11", "BB22"])
    }

    /// 本机仍有私钥的证书永远不进「全撤」候选；序列号前导 0 差异不得漏判（坑位 1）。
    @Test
    func sacrificeCandidatesNeverIncludeKeyfulCertificates() {
        let candidates = CertificateCleanupPolicy.sacrificeCandidates(
            certificates: [makeCertificate("0AA11"), makeCertificate("BB22")],
            localUsableSerials: ["AA11"]
        )
        #expect(candidates.map(\.serialNumber) == ["BB22"])
    }
}
