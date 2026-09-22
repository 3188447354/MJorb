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

    /// 缺账号**不能静默省略**。
    ///
    /// 旧实现在这里 `return nil`，于是「批量续签完成」看起来一切正常，实际有应用
    /// 根本没被处理，用户既看不到它、也不知道为什么。现在必须显式进队列并带上原因。
    @Test
    func appsWithoutBoundAccountsBecomeExplicitRequiresAction() {
        let app = app(name: "Unsigned", expiry: nil, accountID: nil)

        let queue = RefreshPlanner().makeQueue(apps: [app])

        #expect(queue.map(\.appID) == [app.id])
        #expect(queue.first?.state == .requiresAction)
        #expect(queue.first?.accountID == nil)
        #expect(queue.first?.requiresActionReason?.isEmpty == false)
        // 原因必须可执行：只写「跳过」等于没告诉用户下一步做什么
        #expect(queue.first?.requiresActionReason?.contains("账号") == true)
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
        let queue = RefreshPlanner().makeQueue(apps: [seal], fallbackAccountID: unrelated.id, accounts: [unrelated])
        // 不选无关账号是对的；但也不能静默丢掉这个应用 —— 必须显式挂起等用户处理。
        #expect(queue.count == 1)
        #expect(queue.first?.state == .requiresAction)
        #expect(queue.first?.accountID == nil)
    }

    /// `needsAction(in:)` 必须只挑出「本轮未执行」的项，不能把普通待办也算进去。
    @Test
    func needsActionSelectsOnlyRequiresActionItems() {
        let accountID = UUID()
        let runnable = RefreshQueueItem(appID: UUID(), accountID: accountID)
        let pending = RefreshQueueItem(appID: UUID(), accountID: nil, state: .requiresAction, requiresActionReason: "缺账号")
        let failed = RefreshQueueItem(appID: UUID(), accountID: accountID, state: .failed, lastErrorCode: "SEAL-NET-001")

        let selected = RefreshPlanner.needsAction(in: [runnable, pending, failed])

        #expect(selected.map(\.appID) == [pending.appID])
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
