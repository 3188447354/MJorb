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

    /// 典型场景：覆盖安装后 keychain 清空，Apple 侧多张证书全部无钥匙、无关联 App。
    @Test
    func orphanCertificatesWithoutKeyOrAppsAreRevocable() {
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

    /// 已安装 App 在用的证书撤销即闪退，即使本机没有私钥也必须保留。
    @Test
    func certificateUsedByInstalledAppIsKept() {
        let apps = [makeApp(name: "微信", serial: "0AA11")]
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("AA11"), makeCertificate("BB22")],
            apps: apps,
            localUsableSerials: [],
            deviceReferencedSerials: []
        )
        #expect(plan.revocable.map(\.serialNumber) == ["BB22"])
        #expect(plan.kept.map(\.serialNumber) == ["AA11"])
    }

    /// 未安装的记录不受影响（重签即可），不拦截撤销。
    @Test
    func certificateUsedOnlyByNonInstalledAppIsRevocable() {
        let apps = [makeApp(name: "待装", serial: "AA11", state: .signed)]
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("AA11")],
            apps: apps,
            localUsableSerials: [],
            deviceReferencedSerials: []
        )
        #expect(plan.revocable.map(\.serialNumber) == ["AA11"])
    }

    /// 设备端描述文件仍引用的证书 = 设备上仍有 App 靠它运行（可能是其他签名工具装的），必须保留。
    @Test
    func certificateReferencedByDeviceProfileIsKept() {
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("AA11"), makeCertificate("BB22")],
            apps: [],
            localUsableSerials: [],
            deviceReferencedSerials: ["AA11"]
        )
        #expect(plan.revocable.map(\.serialNumber) == ["BB22"])
        #expect(plan.kept.map(\.serialNumber) == ["AA11"])
    }

    /// 设备端核验不可用（未连接隧道）时仍可出候选，但 deviceVerified 必须为 false 让 UI 降级提示。
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

    /// 归一化：前导 0 差异不能让「有私钥/被引用」的证书误入候选（坑位 1）。
    @Test
    func leadingZeroDifferencesDoNotLeakIntoRevocable() {
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: [makeCertificate("0AA11"), makeCertificate("BB22")],
            apps: [],
            localUsableSerials: ["AA11"],
            deviceReferencedSerials: ["0BB22"]
        )
        #expect(plan.revocable.isEmpty)
        #expect(plan.kept.count == 2)
    }

    /// 用户确认后的「全撤」候选只看私钥：在用的无钥匙证书也必须包含（与 makePlan 的分界）。
    @Test
    func sacrificeCandidatesIncludeInUseKeylessCertificates() {
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
