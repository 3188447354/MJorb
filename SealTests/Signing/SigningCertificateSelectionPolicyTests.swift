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

    // MARK: - 悬空绑定（2026-09-25 真机，构建 37）

    /// 🔴 核心回归：记录里绑的账号**已被删除**（删 Apple ID → 重新添加 ⇒ 账号拿到新 UUID），
    /// 而当前账号与它的 Team 相同 ⇒ 必须**放行**，并如实报出「这是悬空回退」。
    ///
    /// 旧实现用裸的 `boundAccountID == account.id` ⇒ 必抛 `SEAL-AUTH-111`，
    /// 真机现象是「只有 Seal 自己能续签，其他应用一律报 Apple ID 不匹配」。
    @Test
    func danglingBindingFallsBackToSameTeam() throws {
        let account = makeAccount(localSerial: "LOCAL", selectedSerial: "LOCAL")
        let danglingAccountID = UUID()
        var app = makeApp(state: .installed)
        app.accountID = danglingAccountID
        app.signingTeamID = account.teamID

        let binding = try SigningCertificateSelectionPolicy.validateAccountAndTeam(
            for: app,
            account: account,
            knownAccountIDs: Set([account.id])
        )

        #expect(binding == .recoveredFromDanglingBinding(previousAccountID: danglingAccountID))
    }

    /// 悬空**不能**成为绕过 Team 判据的后门：Team 不同仍然必须拒绝（换 Team 会让
    /// Bundle ID 前缀 / Keychain 访问组 / App Group 失配）。
    @Test
    func danglingBindingStillRejectsDifferentTeam() {
        let account = makeAccount(localSerial: "LOCAL", selectedSerial: "LOCAL")
        var app = makeApp(state: .installed)
        app.accountID = UUID()
        app.signingTeamID = "OTHERTEAM"

        do {
            try SigningCertificateSelectionPolicy.validateAccountAndTeam(
                for: app,
                account: account,
                knownAccountIDs: Set([account.id])
            )
            Issue.record("Expected Team mismatch failure for dangling binding")
        } catch let failure as ImportFailure {
            #expect(failure.code == "SEAL-AUTH-112")
        } catch {
            Issue.record("Expected ImportFailure, got \(error)")
        }
    }

    /// **保护不丢**：绑定账号**仍在**账号库里（不是悬空）时，选另一个账号必须拒绝 ——
    /// 哪怕 Team 相同。这正是 `SEAL-AUTH-111` 原本要防的「误用其他账号续签」。
    @Test
    func existingBindingRejectsDifferentAccountEvenWhenTeamMatches() {
        let boundAccount = makeAccount(localSerial: "LOCAL", selectedSerial: "LOCAL")
        let otherAccount = makeAccount(localSerial: "LOCAL", selectedSerial: "LOCAL")
        var app = makeApp(state: .installed)
        app.accountID = boundAccount.id
        app.signingTeamID = otherAccount.teamID

        do {
            try SigningCertificateSelectionPolicy.validateAccountAndTeam(
                for: app,
                account: otherAccount,
                knownAccountIDs: Set([boundAccount.id, otherAccount.id])
            )
            Issue.record("Expected Apple ID mismatch for an existing binding")
        } catch let failure as ImportFailure {
            #expect(failure.code == "SEAL-AUTH-111")
        } catch {
            Issue.record("Expected ImportFailure, got \(error)")
        }
    }

    /// 不提供账号库（`nil`）时**保持旧行为**：悬空也拒绝。
    /// 这条钉住「漏改的调用点不会因此变危险」这个前提 —— 默认值必须是保守的。
    @Test
    func missingAccountLibraryKeepsLegacyRejection() {
        let account = makeAccount(localSerial: "LOCAL", selectedSerial: "LOCAL")
        var app = makeApp(state: .installed)
        app.accountID = UUID()
        app.signingTeamID = account.teamID

        do {
            try SigningCertificateSelectionPolicy.validateAccountAndTeam(
                for: app,
                account: account
            )
            Issue.record("Expected Apple ID mismatch when the account library is unknown")
        } catch let failure as ImportFailure {
            #expect(failure.code == "SEAL-AUTH-111")
        } catch {
            Issue.record("Expected ImportFailure, got \(error)")
        }
    }

    /// 绑定账号与所选账号一致时，如实报 `.consistent`（调用方据此决定不写回退日志）。
    @Test
    func exactBindingReportsConsistent() throws {
        let account = makeAccount(localSerial: "LOCAL", selectedSerial: "LOCAL")
        var app = makeApp(state: .installed)
        app.accountID = account.id
        app.signingTeamID = account.teamID

        let binding = try SigningCertificateSelectionPolicy.validateAccountAndTeam(
            for: app,
            account: account,
            knownAccountIDs: Set([account.id])
        )

        #expect(binding == .consistent)
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
