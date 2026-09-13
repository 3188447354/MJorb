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
}
