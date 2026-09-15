import CryptoKit
import Foundation
import Testing
@testable import Seal

struct SelfReplacementCoordinatorTests {
    enum InstallOutcome {
        case success
        case timeout
        case connectionLost
    }

    @Test(arguments: [InstallOutcome.success, .timeout, .connectionLost])
    func submitCallsInstallExactlyOnce(outcome: InstallOutcome) async throws {
        let channel = CountingInstallChannel(outcome: outcome)
        let fixture = try await CoordinatorFixture.make(channel: channel)

        _ = try? await fixture.coordinator.submitPrepared(
            transactionID: fixture.transaction.id,
            progress: { _ in }
        )

        #expect(await channel.installCallCount == 1)
        #expect(try await fixture.store.loadPending()?.submission != nil)
    }

    @Test
    func secondSubmitForSameTransactionIsRejectedBeforeChannelCall() async throws {
        let fixture = try await CoordinatorFixture.make(channel: CountingInstallChannel())
        _ = try? await fixture.coordinator.submitPrepared(
            transactionID: fixture.transaction.id,
            progress: { _ in }
        )
        await #expect(throws: SelfReplacementStoreError.alreadySubmitted) {
            try await fixture.coordinator.submitPrepared(
                transactionID: fixture.transaction.id,
                progress: { _ in }
            )
        }
        #expect(await fixture.channel.installCallCount == 1)
    }

    @Test
    func settleReturnsRunningIdentityAndMarksSettling() async throws {
        let running = InstalledIdentity.fixtureMain()
        let fixture = try await CoordinatorFixture.make(
            channel: CountingInstallChannel(),
            running: running,
            candidate: .matching(running, transactionID: UUID())
        )

        let settled = try await fixture.coordinator.settle()

        #expect(settled.transactionID == fixture.transaction.id)
        #expect(settled.mainBundleIdentifier == "com.example.seal")
        #expect(settled.mainProfileUUID == "PROFILE-UUID")
        #expect(settled.installedIdentity == running)
        #expect(try await fixture.store.loadPending()?.phase == .settling)
    }

    @Test
    func settleRejectsWhenRunningIdentityNoLongerMatchesCandidate() async throws {
        let running = InstalledIdentity.fixtureMain()
        let overwritten = InstalledIdentity.fixtureMain(signerSerialNumber: "OTHER-SERIAL")
        let fixture = try await CoordinatorFixture.make(
            channel: CountingInstallChannel(),
            running: overwritten,
            candidate: .matching(running, transactionID: UUID())
        )

        await #expect(throws: SelfReplacementFailure.candidateChanged) {
            try await fixture.coordinator.settle()
        }
        #expect(try await fixture.store.loadPending()?.phase == .prepared)
    }

    @Test
    func finishCleanupConfirmsTransactionWithAuditSummary() async throws {
        let running = InstalledIdentity.fixtureMain()
        let fixture = try await CoordinatorFixture.make(
            channel: CountingInstallChannel(),
            running: running,
            candidate: .matching(running, transactionID: UUID())
        )
        _ = try await fixture.coordinator.settle()

        var summary = ProfileCleanupSummary()
        summary.scanned = 3
        summary.matched = 2
        summary.removed = 1
        try await fixture.coordinator.finishCleanup(summary)

        #expect(try await fixture.store.loadPending() == nil)
        let persisted = try #require(try await fixture.store.loadAny())
        #expect(persisted.phase == .confirmed)
        #expect(persisted.settledAt != nil)
        #expect(persisted.cleanupSummary == summary.logMessage)
    }

    @Test
    func closeAsNotInstalledClosesTransactionWithoutTouchingChannel() async throws {
        let channel = CountingInstallChannel()
        let fixture = try await CoordinatorFixture.make(channel: channel)

        try await fixture.coordinator.closeAsNotInstalled()

        #expect(try await fixture.store.loadPending() == nil)
        let persisted = try #require(try await fixture.store.loadAny())
        #expect(persisted.phase == .installedOldIdentity)
        #expect(await channel.installCallCount == 0)
    }

    @Test
    func requireRecoveryKeepsTransactionPendingForNextLaunchEvaluation() async throws {
        let fixture = try await CoordinatorFixture.make(channel: CountingInstallChannel())

        try await fixture.coordinator.requireRecovery(reason: "当前 Seal 与安装前身份、候选身份都不一致")

        let pending = try #require(try await fixture.store.loadPending())
        #expect(pending.phase == .recoveryRequired)
        #expect(pending.failureCode == "当前 Seal 与安装前身份、候选身份都不一致")
    }
}

private actor CountingInstallChannel: InstallChannel {
    private(set) var installCallCount = 0
    private let outcome: SelfReplacementCoordinatorTests.InstallOutcome

    init(outcome: SelfReplacementCoordinatorTests.InstallOutcome = .success) {
        self.outcome = outcome
    }

    func start() async throws -> String { "DEVICE-1" }
    func diagnose() async -> InstallChannelDiagnostics { .empty }
    func isReady() async -> Bool { true }
    func pushIpa(ipaData: Data, bundleID: String) async throws {}
    func installPushedIpa(bundleID: String, isSelfReplacement: Bool) async throws {}
    func install(ipaData: Data, bundleID: String, isSelfReplacement: Bool) async throws {
        installCallCount += 1
        switch outcome {
        case .success: break
        case .timeout: throw CancellationError()
        case .connectionLost: throw ImportFailure(title: "连接丢失", reason: "fixture", recovery: "重试", code: "SEAL-INSTALL-001")
        }
    }
    func verifyInstalled(bundleID: String) async throws {}
}

private struct CoordinatorFixture {
    let coordinator: SelfReplacementCoordinator
    let store: SelfReplacementTransactionStore
    let transaction: SelfReplacementTransaction
    let channel: CountingInstallChannel

    static func make(
        channel: CountingInstallChannel,
        running: InstalledIdentity? = nil,
        candidate: CandidateIdentity? = nil
    ) async throws -> CoordinatorFixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SealCoordinatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let cache = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let store = SelfReplacementTransactionStore(
            fileURL: root.appending(path: "SelfSigningHandoff.json")
        )
        let fileStore = AppFileStore(documentsDirectory: documents, cacheDirectory: cache)
        // submitPrepared 会读取候选 IPA 并校验 SHA-256，必须与事务记录一致。
        let signedData = Data("signed-ipa".utf8)
        let signedURL = documents.appending(path: "Apps/Seal/Signed.ipa")
        try FileManager.default.createDirectory(
            at: signedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try signedData.write(to: signedURL)
        let signedSHA = SHA256.hash(data: signedData).map { String(format: "%02X", $0) }.joined()
        let transaction = SelfReplacementTransaction.fixture(
            candidate: candidate,
            ipaSHA256: signedSHA
        )
        _ = try await store.create(transaction)

        let coordinator = SelfReplacementCoordinator(
            store: store,
            readRunningIdentity: { running ?? .unknown(bundleIdentifier: "com.example.seal") },
            ipaIdentityReader: SignedIPAIdentityReader(
                bundleReader: AppBundleSigningIdentityReader { _ in
                    .init(serialNumber: "ABC123", cmsValid: true, codeDirectoryValid: true)
                }
            ),
            installChannel: channel,
            fileStore: fileStore,
            keychain: KeychainVault(),
            processID: SelfReplacementProcess.currentID
        )
        return CoordinatorFixture(
            coordinator: coordinator,
            store: store,
            transaction: transaction,
            channel: channel
        )
    }
}

private extension SelfReplacementTransaction {
    static func fixture(
        candidate: CandidateIdentity? = nil,
        ipaSHA256: String
    ) -> SelfReplacementTransaction {
        let id = UUID()
        let resolvedCandidate = candidate ?? CandidateIdentity(
            transactionID: id,
            ipaSHA256: ipaSHA256,
            version: "",
            buildNumber: "",
            targets: [SignedTargetIdentity(
                kind: .mainApp,
                bundleIdentifier: "com.example.seal",
                teamIdentifier: "TEAM",
                applicationIdentifier: "",
                profileUUID: "PROFILE-UUID",
                profileExpirationDate: .distantPast,
                signerSerialNumber: "ABC123",
                signerCertificateSHA256: "",
                status: .unreadable
            )]
        )
        return SelfReplacementTransaction.make(
            id: id,
            accountID: UUID(),
            preparedProcessID: UUID(),
            installedBefore: .unknown(bundleIdentifier: "com.example.seal"),
            candidate: resolvedCandidate,
            signedIPARelativePath: "Apps/Seal/Signed.ipa"
        )
    }
}

extension InstalledIdentity {
    static func fixtureMain(
        bundleIdentifier: String = "com.example.seal",
        version: String = "1.0",
        buildNumber: String = "1",
        teamIdentifier: String = "TEAM",
        profileUUID: String = "PROFILE-UUID",
        signerSerialNumber: String = "ABC123"
    ) -> InstalledIdentity {
        InstalledIdentity(
            bundleURL: URL(fileURLWithPath: "/Running/Seal.app"),
            version: version,
            buildNumber: buildNumber,
            targets: [SignedTargetIdentity(
                kind: .mainApp,
                bundleIdentifier: bundleIdentifier,
                teamIdentifier: teamIdentifier,
                applicationIdentifier: "\(teamIdentifier).\(bundleIdentifier)",
                profileUUID: profileUUID,
                profileExpirationDate: Date(timeIntervalSince1970: 1_800_000_000),
                signerSerialNumber: signerSerialNumber,
                signerCertificateSHA256: "SHA256",
                status: .complete
            )],
            readErrors: []
        )
    }
}

extension CandidateIdentity {
    static func matching(_ running: InstalledIdentity, transactionID: UUID) -> CandidateIdentity {
        CandidateIdentity(
            transactionID: transactionID,
            ipaSHA256: "IPA-SHA",
            version: running.version,
            buildNumber: running.buildNumber,
            targets: running.targets
        )
    }
}
