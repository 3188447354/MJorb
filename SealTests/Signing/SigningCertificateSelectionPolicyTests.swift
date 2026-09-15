import Foundation
import Testing
@testable import Seal

struct SigningCertificateSelectionPolicyTests {
    @Test
    func newSigningUsesCurrentLocallyUsableCertificate() throws {
        let account = makeAccount(localSerial: "LOCAL", selectedSerial: "REMOTE")
        let app = makeApp(state: .imported)

        #expect(
            try SigningCertificateSelectionPolicy.resolvedSerialNumber(
                for: app,
                account: account
            ) == "LOCAL"
        )
    }

    @Test
    func renewalUsesCurrentLocallyUsableAccountCertificate() throws {
        let account = makeAccount(localSerial: "NEW", selectedSerial: "NEW")
        var app = makeApp(state: .installed)
        app.accountID = account.id
        app.signingTeamID = account.teamID
        app.certificateSerialNumber = "OLD"

        #expect(
            try SigningCertificateSelectionPolicy.resolvedSerialNumber(
                for: app,
                account: account
            ) == "NEW"
        )
    }

    @Test
    func arbitraryRequestedCertificateCannotOverrideLocalCertificate() throws {
        let account = makeAccount(localSerial: "LOCAL", selectedSerial: "LOCAL")
        let app = makeApp(state: .imported)

        #expect(
            try SigningCertificateSelectionPolicy.resolvedSerialNumber(
                for: app,
                account: account,
                requestedSerialNumber: "REMOTE"
            ) == "LOCAL"
        )
    }

    @Test
    func localAvailabilityDetectsMissingPrivateKeyForSelectedCertificate() {
        let account = makeAccount(localSerial: nil, selectedSerial: "REMOTE")
        let app = makeApp(state: .imported)

        #expect(
            SigningCertificateSelectionPolicy.localAvailabilityMessage(
                for: app,
                account: account
            ) != nil
        )
    }


    @Test
    func renewalRejectsMissingPreviousTeam() {
        let account = makeAccount(localSerial: "LOCAL", selectedSerial: "LOCAL")
        var app = makeApp(state: .installed)
        app.accountID = account.id
        app.signingTeamID = nil

        #expect(throws: ImportFailure.self) {
            try SigningCertificateSelectionPolicy.validateAccountAndTeam(
                for: app,
                account: account
            )
        }
    }

    @Test
    func renewalTeamMismatchRequestsExplicitTeamSelection() throws {
        let account = makeAccount(localSerial: "LOCAL", selectedSerial: "LOCAL")
        var app = makeApp(state: .installed)
        app.accountID = account.id
        app.signingTeamID = "OTHERTEAM"

        do {
            try SigningCertificateSelectionPolicy.validateAccountAndTeam(
                for: app,
                account: account
            )
            Issue.record("Expected Team mismatch failure")
        } catch let failure as ImportFailure {
            #expect(failure.code == "SEAL-AUTH-112")
            #expect(failure.recovery == "使用原开发者团队的 Apple ID 续签，或用当前账号重新签名安装")
        }
    }

    @Test
    func renewalRejectsDifferentAccountAndTeam() {
        let account = makeAccount(localSerial: "LOCAL", selectedSerial: "LOCAL")
        var app = makeApp(state: .installed)
        app.accountID = UUID()
        app.signingTeamID = "ORIGINALTEAM"

        #expect(throws: ImportFailure.self) {
            try SigningCertificateSelectionPolicy.validateAccountAndTeam(
                for: app,
                account: account
            )
        }
    }

    /// Seal 自保护：读不到 Seal 的 Team（爱思/其他工具签的包常常取不到 teamIdentifier）
    /// 必须拦截续签，绝不放行——放行会导致跨团队续签、签名身份变更、装完变砖。
    @Test
    func sealRenewalRejectsMissingTeam() {
        let account = makeAccount(localSerial: "LOCAL", selectedSerial: "LOCAL")
        var app = makeApp(state: .installed, isSeal: true)
        app.signingTeamID = nil

        do {
            try SigningCertificateSelectionPolicy.validateAccountAndTeam(
                for: app,
                account: account
            )
            Issue.record("Expected missing-team failure for Seal")
        } catch let failure as ImportFailure {
            #expect(failure.code == "SEAL-SELF-104")
        } catch {
            Issue.record("Expected ImportFailure, got \(error)")
        }
    }

    /// Seal 自保护：Team 不匹配必须拦截。爱思签的 Seal 用自己 Apple ID 续签会撞到这里。
    @Test
    func sealRenewalRejectsTeamMismatch() {
        let account = makeAccount(localSerial: "LOCAL", selectedSerial: "LOCAL")
        var app = makeApp(state: .installed, isSeal: true)
        app.signingTeamID = "AISITEAM"

        do {
            try SigningCertificateSelectionPolicy.validateAccountAndTeam(
                for: app,
                account: account
            )
            Issue.record("Expected team-mismatch failure for Seal")
        } catch let failure as ImportFailure {
            #expect(failure.code == "SEAL-SELF-103")
        } catch {
            Issue.record("Expected ImportFailure, got \(error)")
        }
    }

    /// Seal 自保护：Team 一致时放行（这是 Seal 自己签的，正常续签路径）。
    @Test
    func sealRenewalAllowsMatchingTeam() throws {
        let account = makeAccount(localSerial: "LOCAL", selectedSerial: "LOCAL")
        var app = makeApp(state: .installed, isSeal: true)
        app.signingTeamID = account.teamID

        try SigningCertificateSelectionPolicy.validateAccountAndTeam(
            for: app,
            account: account
        )
    }

    private func makeAccount(
        localSerial: String?,
        selectedSerial: String?
    ) -> AppleAccountRecord {
        AppleAccountRecord(
            maskedEmail: "s***@example.com",
            accountIdentifier: "account",
            teamID: "TEAMID",
            teamName: "Personal Team",
            isFreeTeam: true,
            status: .verified,
            certificateSerialNumber: localSerial,
            selectedCertificateSerialNumber: selectedSerial,
            lastVerifiedAt: Date()
        )
    }

    private func makeApp(state: AppState, isSeal: Bool = false) -> AppRecord {
        AppRecord(
            originalBundleIdentifier: "com.example.app",
            name: "Example",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: state,
            ipaRelativePath: "Apps/example.ipa",
            isSeal: isSeal,
            importedAt: Date()
        )
    }
}
