import Foundation
import Testing
@testable import Seal

struct CertificateRevocationImpactTests {
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

    private func makeAccount(serial: String?) -> AppleAccountRecord {
        AppleAccountRecord(
            maskedEmail: "a@example.com",
            accountIdentifier: "1",
            teamID: "TEAM123456",
            teamName: "Example",
            certificateSerialNumber: serial,
            lastVerifiedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// AltSign 会剥掉前导 0，DER 来源会保留：同一证书的两种写法都必须命中（DEBUG_LOG 坑位 1）。
    @Test
    func matchesCertificateAcrossLeadingZeroDifferences() {
        let app = makeApp(name: "Alpha", serial: "0E76A893")
        #expect(CertificateRevocationImpact.affectedApps(serialNumber: "E76A893", apps: [app]).count == 1)
        #expect(CertificateRevocationImpact.affectedApps(serialNumber: "0E76A893", apps: [app]).count == 1)
    }

    @Test
    func ignoresAppsSignedWithOtherCertificates() {
        let apps = [makeApp(name: "Alpha", serial: "AA11"), makeApp(name: "Beta", serial: "BB22")]
        let affected = CertificateRevocationImpact.affectedApps(serialNumber: "AA11", apps: apps)
        #expect(affected.map(\.name) == ["Alpha"])
    }

    @Test
    func ignoresAppsWithoutCertificateRecord() {
        let apps = [makeApp(name: "Alpha", serial: nil), makeApp(name: "Beta", serial: "")]
        #expect(CertificateRevocationImpact.affectedApps(serialNumber: "AA11", apps: apps).isEmpty)
    }

    /// 扩展 target 也属于证书关联：顶层 serial 为空时不能把 Widget/通知扩展漏掉。
    @Test
    func associatedAppsIncludesCertificatesRecordedOnlyOnAnExtensionTarget() {
        let target = SigningTargetRecord(
            bundleIdentifier: "com.example.Alpha.widget",
            profileUUID: "PROFILE-1",
            profileName: "Widget",
            profileCreationDate: nil,
            profileExpirationDate: Date(timeIntervalSince1970: 2_000_000_000),
            teamIdentifier: "TEAM123456",
            certificateSerialNumbers: ["0AA11"],
            deviceIdentifiers: [],
            entitlementKeys: []
        )
        let app = AppRecord(
            originalBundleIdentifier: "com.example.Alpha",
            name: "Alpha",
            version: "1.0",
            buildNumber: "1",
            size: 1024,
            state: .signed,
            signingTargets: [target],
            ipaRelativePath: "Alpha.ipa",
            importedAt: Date(timeIntervalSince1970: 0)
        )

        let associated = CertificateRevocationImpact.associatedApps(
            serialNumber: "AA11",
            apps: [app]
        )
        #expect(associated.map(\.name) == ["Alpha"])
    }

    /// 只导入 / 已签名但未安装的包，重新签一次即可，不算受影响。
    @Test
    func ignoresAppsThatAreNotInstalled() {
        let apps = [
            makeApp(name: "Alpha", serial: "AA11", state: .signed),
            makeApp(name: "Beta", serial: "AA11", state: .imported)
        ]
        #expect(CertificateRevocationImpact.affectedApps(serialNumber: "AA11", apps: apps).isEmpty)
    }

    @Test
    func detectsLocalCertificateAcrossLeadingZeroDifferences() {
        let account = makeAccount(serial: "0E76A893")
        #expect(CertificateRevocationImpact.isLocalCertificate(serialNumber: "E76A893", account: account))
        #expect(
            CertificateRevocationImpact.isLocalCertificate(serialNumber: "AABBCC", account: account) == false
        )
    }

    @Test
    func localCertificateIsFalseWhenAccountHasNoCertificate() {
        let account = makeAccount(serial: nil)
        #expect(
            CertificateRevocationImpact.isLocalCertificate(serialNumber: "AA11", account: account) == false
        )
    }

    @Test
    func warningNamesAffectedAppsAndFlagsLocalCertificate() {
        let apps = [makeApp(name: "微信", serial: "AA11"), makeApp(name: "短剧", serial: "AA11")]
        let message = CertificateRevocationImpact.warningMessage(
            serialNumber: "AA11",
            apps: apps,
            isLocalCertificate: true
        )
        #expect(message.contains("微信"))
        #expect(message.contains("短剧"))
        #expect(message.contains("无法恢复"))
        #expect(message.contains("本机当前使用"))
    }

    @Test
    func warningSaysNothingIsAffectedWhenNoAppMatches() {
        let message = CertificateRevocationImpact.warningMessage(
            serialNumber: "AA11",
            apps: [makeApp(name: "Beta", serial: "BB22")],
            isLocalCertificate: false
        )
        #expect(message.contains("没有已安装的应用"))
        #expect(message.contains("本机当前使用") == false)
    }

    /// 真实签名者判定必须归一化前导 0：AltSign 剥 0、DER 保留 0 是同一张证书（坑位 1）。
    @Test
    func actualSealSignerMatchesAcrossLeadingZeroDifferences() {
        #expect(
            CertificateRevocationImpact.isActualSealSigner(
                serialNumber: "0E76A893",
                actualSealSignerSerialNumber: "E76A893"
            )
        )
        #expect(
            CertificateRevocationImpact.isActualSealSigner(
                serialNumber: "E76A893",
                actualSealSignerSerialNumber: "0E76A893"
            )
        )
        #expect(
            CertificateRevocationImpact.isActualSealSigner(
                serialNumber: "AABBCC",
                actualSealSignerSerialNumber: "E76A893"
            ) == false
        )
    }

    /// 真实签名者未知时，判定结果必须为 false —— 由调用方在「未知」时整体停止撤销，
    /// 这里的 false 只表示「无法证明这张证书是 A」，绝不表示「可以放心撤」。
    @Test
    func actualSealSignerIsFalseWhenSignerUnknown() {
        #expect(
            CertificateRevocationImpact.isActualSealSigner(
                serialNumber: "AA11",
                actualSealSignerSerialNumber: nil
            ) == false
        )
        #expect(
            CertificateRevocationImpact.isActualSealSigner(
                serialNumber: "AA11",
                actualSealSignerSerialNumber: ""
            ) == false
        )
    }

    // MARK: - 证书卡片「本机已安装 App」清单

    private func makeTargetOnlyApp(
        name: String,
        serial: String,
        state: AppState,
        isSeal: Bool = false
    ) -> AppRecord {
        let target = SigningTargetRecord(
            bundleIdentifier: "com.example.\(name).widget",
            profileUUID: "PROFILE-\(name)",
            profileName: "Widget",
            profileCreationDate: nil,
            profileExpirationDate: Date(timeIntervalSince1970: 2_000_000_000),
            teamIdentifier: "TEAM123456",
            certificateSerialNumbers: [serial],
            deviceIdentifiers: [],
            entitlementKeys: []
        )
        return AppRecord(
            originalBundleIdentifier: "com.example.\(name)",
            name: name,
            version: "1.0",
            buildNumber: "1",
            size: 1024,
            state: state,
            signingTargets: [target],
            ipaRelativePath: "\(name).ipa",
            isSeal: isSeal,
            importedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// 清单必须与行标签（associatedApps）同源：只在签名 target 上记录证书的 App 也要出现。
    /// 同时确认撤销影响评估 affectedApps 的口径没被改动（仍只看顶层序列号）。
    @Test
    func installedAppsAssociatedFollowsTheSameRuleAsTheRowLabel() {
        let app = makeTargetOnlyApp(name: "Alpha", serial: "0AA11", state: .installed)
        #expect(
            CertificateRevocationImpact.associatedApps(serialNumber: "AA11", apps: [app])
                .map(\.name) == ["Alpha"]
        )
        #expect(
            CertificateRevocationImpact.installedAppsAssociated(serialNumber: "AA11", apps: [app])
                .map(\.name) == ["Alpha"]
        )
        #expect(CertificateRevocationImpact.affectedApps(serialNumber: "AA11", apps: [app]).isEmpty)
    }

    /// Seal 自身的 state 可能不是 .installed（belongsInInstalledList 恒为真）。
    /// 旧实现直接用 affectedApps，于是续签后「此证书已安装 App」里看不到 Seal。
    @Test
    func installedAppsAssociatedAlwaysIncludesSeal() {
        let seal = makeTargetOnlyApp(name: "Seal", serial: "AA11", state: .signed, isSeal: true)
        #expect(CertificateRevocationImpact.affectedApps(serialNumber: "AA11", apps: [seal]).isEmpty)
        #expect(
            CertificateRevocationImpact.installedAppsAssociated(serialNumber: "AA11", apps: [seal])
                .map(\.name) == ["Seal"]
        )
    }

    /// 清单只展示「本机已安装」的记录：未安装的普通 App 不进清单，也不进撤销影响。
    @Test
    func installedAppsAssociatedExcludesAppsThatAreNotInstalled() {
        let apps = [
            makeApp(name: "Alpha", serial: "AA11", state: .imported),
            makeApp(name: "Beta", serial: "AA11", state: .signed)
        ]
        #expect(CertificateRevocationImpact.installedAppsAssociated(serialNumber: "AA11", apps: apps).isEmpty)
    }
}
