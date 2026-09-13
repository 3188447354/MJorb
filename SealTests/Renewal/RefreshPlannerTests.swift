import Foundation
import Testing
@testable import Seal

struct RefreshPlannerTests {
    @Test
    func placesSealAfterUrgentAndRegularApps() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let accountID = UUID()
        let regular = app(
            name: "Regular",
            expiry: now.addingTimeInterval(5 * 86_400),
            accountID: accountID
        )
        let urgent = app(
            name: "Urgent",
            expiry: now.addingTimeInterval(3_600),
            accountID: accountID
        )
        let seal = app(
            name: "Seal",
            expiry: now.addingTimeInterval(6 * 86_400),
            accountID: accountID,
            isSeal: true
        )

        let queue = RefreshPlanner().makeQueue(
            apps: [regular, urgent, seal],
            now: now
        )

        #expect(queue.map(\.appID) == [urgent.id, regular.id, seal.id])
    }

    @Test
    func placesSealLastEvenWhenSealExpiresFirst() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let accountID = UUID()
        let regular = app(
            name: "Regular",
            expiry: now.addingTimeInterval(5 * 86_400),
            accountID: accountID
        )
        let seal = app(
            name: "Seal",
            expiry: now.addingTimeInterval(60),
            accountID: accountID,
            isSeal: true
        )

        let queue = RefreshPlanner().makeQueue(
            apps: [seal, regular],
            now: now
        )

        #expect(queue.map(\.appID) == [regular.id, seal.id])
    }

    @Test
    func skipsAppsWithoutBoundAccounts() {
        let app = app(name: "Unsigned", expiry: nil, accountID: nil)

        #expect(RefreshPlanner().makeQueue(apps: [app]).isEmpty)
    }

    @Test
    func includesPreviouslyInstalledAppsDuringRenewal() {
        var app = app(
            name: "Interrupted",
            expiry: Date(timeIntervalSince1970: 2_000_000_000),
            accountID: UUID()
        )
        app.state = .signing
        app.lastInstalledAt = Date(timeIntervalSince1970: 1_999_000_000)
        app.signedArtifactStatus = .installFailed

        let queue = RefreshPlanner().makeQueue(apps: [app])

        #expect(queue.map(\.appID) == [app.id])
    }

    @Test
    func sealTeamMatchTakesPriorityOverUnrelatedDefaultAccount() {
        let correct = AppleAccountRecord(maskedEmail: "b***", accountIdentifier: "b", teamID: "TEAM-B", teamName: "B", lastVerifiedAt: Date())
        let unrelated = AppleAccountRecord(maskedEmail: "a***", accountIdentifier: "a", teamID: "TEAM-A", teamName: "A", lastVerifiedAt: Date())
        var seal = app(name: "Seal", expiry: nil, accountID: nil, isSeal: true)
        seal.signingTeamID = "team-b"
        let queue = RefreshPlanner().makeQueue(apps: [seal], fallbackAccountID: unrelated.id, accounts: [unrelated, correct])
        #expect(queue.first?.accountID == correct.id)
    }

    @Test
    func sealDoesNotSelectUnrelatedDefaultWhenTeamHasNoMatch() {
        let unrelated = AppleAccountRecord(maskedEmail: "a***", accountIdentifier: "a", teamID: "TEAM-A", teamName: "A", lastVerifiedAt: Date())
        var seal = app(name: "Seal", expiry: nil, accountID: nil, isSeal: true)
        seal.signingTeamID = "TEAM-B"
        #expect(RefreshPlanner().makeQueue(apps: [seal], fallbackAccountID: unrelated.id, accounts: [unrelated]).isEmpty)
    }

    @Test(arguments: ["SEAL-AUTH-107", "SEAL-AUTH-105a", "SEAL-CERT-204b", "SEAL-SIGN-405", "SEAL-INSTALL-702", "SEAL-INSTALL-702l", "SEAL-INSTALL-730"])
    func deterministicAndAlreadyRetriedFailuresAreNotRetried(code: String) {
        let failure = ImportFailure(title: "失败", reason: "fixture", recovery: "人工处理", code: code)
        #expect(RenewalCoordinator.isRetryable(failure) == false)
    }

    @Test
    func transientNetworkFailureIsRetryableButCancellationIsNot() {
        let failure = ImportFailure(title: "网络失败", reason: "fixture", recovery: "重试", code: "SEAL-NET-001")
        #expect(RenewalCoordinator.isRetryable(failure))
        #expect(RenewalCoordinator.isRetryable(CancellationError()) == false)
    }

    private func app(
        name: String,
        expiry: Date?,
        accountID: UUID?,
        isSeal: Bool = false
    ) -> AppRecord {
        AppRecord(
            originalBundleIdentifier: "com.example.\(name.lowercased())",
            name: name,
            version: "1",
            buildNumber: "1",
            size: 1,
            state: .installed,
            expiryDate: expiry,
            accountID: accountID,
            ipaRelativePath: "Apps/\(UUID().uuidString)/Original.ipa",
            isSeal: isSeal,
            importedAt: Date()
        )
    }
}
