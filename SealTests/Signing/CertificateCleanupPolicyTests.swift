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

    // MARK: - makePlan（新策略：无私钥一律撤）

    /// 全部无钥匙、无关联 App 的证书一律可撤。
    @Test
    func orphanCertificatesWithoutKeyAreRevocable() {
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("AA11"), makeCertificate("0BB22")],
            apps: [],
            localUsableSerials: [],
            deviceReferencedSerials: []
        )
        #expect(plan.revocable.map(\.serialNumber) == ["AA11", "0BB22"])
        #expect(plan.kept.isEmpty)
        #expect(plan.deviceVerified)
    }

    /// 本机仍存 P12 的证书（含历史 map 里的）绝不能撤：它还能无感复用。
    @Test
    func certificateWithLocalPrivateKeyIsKept() {
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("AA11"), makeCertificate("BB22")],
            apps: [],
            localUsableSerials: ["BB22"],
            deviceReferencedSerials: []
        )
        #expect(plan.revocable.map(\.serialNumber) == ["AA11"])
        #expect(plan.kept.map(\.serialNumber) == ["BB22"])
    }

    /// 新策略：即使已安装 App 在用，只要本机无私钥也一律撤（留着也没法签新包）。
    /// 与旧版的核心区别：不再因为「关联 App 在用」就保留。
    @Test
    func certificateUsedByInstalledAppIsStillRevocableIfNoLocalKey() {
        let apps = [makeApp(name: "微信", serial: "0AA11")]
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("AA11"), makeCertificate("BB22")],
            apps: apps,
            localUsableSerials: [],
            deviceReferencedSerials: []
        )
        // 两张都无私钥 → 两张都可撤（不再因关联 App 而保留）
        #expect(plan.revocable.count == 2)
        #expect(plan.kept.isEmpty)
    }

    /// 新策略：设备端 profile 引用的证书，只要本机无私钥也一律撤。
    /// 与旧版的核心区别：不再因为「设备端在用」就保留。
    @Test
    func certificateReferencedByDeviceProfileIsStillRevocableIfNoLocalKey() {
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("AA11"), makeCertificate("BB22")],
            apps: [],
            localUsableSerials: [],
            deviceReferencedSerials: ["AA11"]
        )
        // 两张都无私钥 → 两张都可撤（不再因设备端引用而保留）
        #expect(plan.revocable.count == 2)
        #expect(plan.kept.isEmpty)
    }

    /// 设备端核验不可用（未连接隧道）时 deviceVerified 为 false，但不影响可撤判定。
    @Test
    func unverifiedDeviceMarksPlanAsNotDeviceVerified() {
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("AA11")],
            apps: [],
            localUsableSerials: [],
            deviceReferencedSerials: nil
        )
        #expect(plan.revocable.count == 1)
        #expect(plan.deviceVerified == false)
    }

    /// 归一化：前导 0 差异不能让「有私钥」的证书误入候选（坑位 1）。
    @Test
    func leadingZeroDifferencesDoNotLeakIntoRevocable() {
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("0AA11"), makeCertificate("BB22")],
            apps: [],
            localUsableSerials: ["AA11"],
            deviceReferencedSerials: ["0BB22"]
        )
        // 只有 BB22 无私钥 → 只有 BB22 可撤（AA11 有私钥所以保留）
        #expect(plan.revocable.map(\.serialNumber) == ["BB22"])
        #expect(plan.kept.map(\.serialNumber) == ["0AA11"])
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
