import Foundation
import Testing
@testable import Seal

struct SelfAppPendingHandoffTests {
    @Test
    func oldRunningBundleCorrectsInstalledSnapshotWithoutDiscardingUpdateSource() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SealPendingHandoff-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let cache = root.appending(path: "Caches", directoryHint: .isDirectory)
        let id = UUID()
        let relativePath = "Apps/\(id.uuidString)/Original.ipa"
        let source = documents.appending(path: relativePath)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceData = Data("keep pending update source".utf8)
        try sourceData.write(to: source)
        let appStore = try CoreDataAppStore(inMemory: true)
        let fileStore = AppFileStore(documentsDirectory: documents, cacheDirectory: cache)
        let oldExpiry = Date(timeIntervalSince1970: 1_700_000_000)
        let newExpiry = oldExpiry.addingTimeInterval(6 * 86_400)
        let target = SigningTargetRecord(
            bundleIdentifier: "com.mjorb.seal", profileUUID: "NEW", profileName: "New",
            profileCreationDate: nil, profileExpirationDate: newExpiry, teamIdentifier: "TEAM",
            certificateSerialNumbers: ["ABC"], deviceIdentifiers: [], entitlementKeys: []
        )
        let app = AppRecord(
            id: id, originalBundleIdentifier: "com.mjorb.seal", name: "Seal", version: "2.0",
            buildNumber: "2", size: 100, state: .installed, expiryDate: newExpiry,
            signingTeamID: "TEAM", certificateSerialNumber: "ABC", provisioningProfileUUID: "NEW",
            provisioningProfileExpirationDate: newExpiry, signingTargets: [target],
            ipaRelativePath: relativePath, signedIPARelativePath: "pending-signed.ipa",
            signedArtifactStatus: .installed, hasPendingSelfUpdateSource: true, isSeal: true,
            importedAt: .distantPast
        )
        try await appStore.save(app)
        let registrar = SelfAppRegistrar(
            metadata: SelfAppMetadata(
                bundleURL: root.appending(path: "Running.app"), bundleIdentifier: "com.mjorb.seal",
                originalBundleIdentifier: nil, name: "Seal", version: "1.0", buildNumber: "1", iconData: nil,
                expirationDate: oldExpiry, signingTeamIdentifier: "TEAM", signingApplicationIdentifier: nil,
                provisioningProfileUUID: "OLD", certificateSerialNumbers: ["DEF"]
            ),
            appStore: appStore, accountRepository: HandoffEmptyAccountRepository(), fileStore: fileStore
        )
        try await registrar.ensureRegistered()
        let updated = try #require(try await appStore.fetchAll().first)
        #expect(updated.expiryDate == oldExpiry)
        #expect(updated.provisioningProfileUUID == "OLD")
        #expect(updated.certificateSerialNumber == "DEF")
        #expect(updated.signedArtifactStatus == .awaitingVerification)
        #expect(updated.signingTargets == [target])
        #expect(updated.version == "2.0")
        #expect(updated.hasPendingSelfUpdateSource)
        #expect(updated.signedIPARelativePath == app.signedIPARelativePath)
        #expect(try Data(contentsOf: source) == sourceData)
    }

    @Test
    func startupReconciliationNeverSubmitsAnotherInstall() async throws {
        let fixture = try await ReplacementRegistrarFixture.make(action: .settle)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try await fixture.registrar.ensureRegistered()

        // 启动对账绝不触碰安装链路：prepare/submit 只能在签名流程里发生。
        #expect(await fixture.replacement.prepareCallCount == 0)
        #expect(await fixture.replacement.submitCallCount == 0)
    }

    @Test
    func confirmedReplacementAdvancesRecordBeforeCleaningOldProfile() async throws {
        let fixture = try await ReplacementRegistrarFixture.make(action: .settle)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try await fixture.registrar.ensureRegistered()

        let app = try #require(try await fixture.appStore.fetchAll().first(where: { $0.isSeal }))
        #expect(app.certificateSerialNumber == ReplacementRegistrarFixture.candidateSigner)
        #expect(app.provisioningProfileUUID == ReplacementRegistrarFixture.candidateProfileUUID)
        #expect(app.signingTeamID == ReplacementRegistrarFixture.candidateTeam)
        #expect(app.signedArtifactStatus == .installed)
        // 清理必须发生在记录推进之后，且保留的是候选身份的主 profile。
        #expect(await fixture.profileCleaner.requests.map(\.keepingProfileUUID) == [ReplacementRegistrarFixture.candidateProfileUUID])
        #expect(await fixture.profileCleaner.recordSerialAtCall == ReplacementRegistrarFixture.candidateSigner)
        // 事务已确认关闭：同一事务不会在下一次启动被重复结算。
        #expect(try await fixture.transactionStore.loadPending() == nil)
    }

    @Test
    func interruptedSelfRenewalRemainsUnknownAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SealQueueHandoff-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "queue.json")
        let store = RefreshQueueStore(fileURL: fileURL, fileProtector: MarkerFileProtector())
        let item = RefreshQueueItem(appID: UUID(), accountID: UUID())
        try await store.replace(with: [item])
        try await store.markRunning(appID: item.appID)
        let restarted = RefreshQueueStore(fileURL: fileURL, fileProtector: MarkerFileProtector())
        #expect(try await restarted.recoverInterrupted() == 1)
        let outstanding = try await restarted.outstanding()
        #expect(outstanding.count == 1)
        #expect(outstanding.first?.state == .unknown)
        #expect(outstanding.first?.id == item.id)
    }
}

private actor HandoffEmptyAccountRepository: AccountRepository {
    func fetchAll() throws -> [AppleAccountRecord] { [] }
    func save(_ account: AppleAccountRecord) throws {}
    func delete(id: UUID) throws {}
}

private actor StubSelfReplacement: SelfReplacing {
    let action: SelfReplacementReconcileAction
    private var settlePayload: SettledSelfReplacement?
    private let store: SelfReplacementTransactionStore?
    private(set) var prepareCallCount = 0
    private(set) var submitCallCount = 0
    private(set) var settleCallCount = 0
    private(set) var finishCleanupSummaries: [ProfileCleanupSummary] = []
    private(set) var closeAsNotInstalledCount = 0
    private(set) var recoveryReasons: [String] = []

    init(action: SelfReplacementReconcileAction, store: SelfReplacementTransactionStore?) {
        self.action = action
        self.store = store
    }

    func setSettlePayload(_ payload: SettledSelfReplacement) {
        settlePayload = payload
    }

    func prepare(app: AppRecord, accountID: UUID, signedIPARelativePath: String) async throws -> SelfReplacementTransaction {
        prepareCallCount += 1
        throw SelfReplacementStoreError.pendingNotFound
    }

    func submitPrepared(transactionID: UUID, progress: @escaping @Sendable (Double) async -> Void) async throws {
        submitCallCount += 1
    }

    func reconcileAtLaunch() async throws -> SelfReplacementReconcileAction { action }

    func settle() async throws -> SettledSelfReplacement {
        settleCallCount += 1
        guard let settlePayload else { throw SelfReplacementFailure.candidateChanged }
        return settlePayload
    }

    func closeAsNotInstalled() async throws {
        closeAsNotInstalledCount += 1
        if let store, let pending = try await store.loadPending() {
            try await store.close(transactionID: pending.id, phase: .installedOldIdentity)
        }
    }

    func requireRecovery(reason: String) async throws {
        recoveryReasons.append(reason)
        if let store, let pending = try await store.loadPending() {
            try await store.updatePhase(transactionID: pending.id, phase: .recoveryRequired, failureCode: reason)
        }
    }

    func finishCleanup(_ summary: ProfileCleanupSummary) async throws {
        finishCleanupSummaries.append(summary)
        if let store, let pending = try await store.loadPending() {
            try await store.close(transactionID: pending.id, phase: .confirmed, cleanupSummary: summary.logMessage)
        }
    }
}

private actor RecordingProfileCleaner: SelfReplacementProfileCleaning {
    private let appStore: CoreDataAppStore
    private(set) var requests: [ProfileCleanupRequest] = []
    private(set) var recordSerialAtCall: String?

    init(appStore: CoreDataAppStore) {
        self.appStore = appStore
    }

    func removeStaleProfiles(_ request: ProfileCleanupRequest) async -> ProfileCleanupSummary {
        requests.append(request)
        recordSerialAtCall = try? await appStore.fetchAll().first(where: { $0.isSeal })?.certificateSerialNumber
        return ProfileCleanupSummary(stage: "done")
    }
}

private struct ReplacementRegistrarFixture {
    static let candidateSigner = "ABC"
    static let candidateTeam = "TEAM"
    static let candidateProfileUUID = "NEW-PROFILE"
    static let candidateExpiry = Date(timeIntervalSince1970: 1_800_000_000)

    let root: URL
    let registrar: SelfAppRegistrar
    let appStore: CoreDataAppStore
    let transactionStore: SelfReplacementTransactionStore
    let replacement: StubSelfReplacement
    let profileCleaner: RecordingProfileCleaner

    static func make(action: SelfReplacementReconcileAction) async throws -> ReplacementRegistrarFixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SealReplacementRegistrar-\(UUID().uuidString)", directoryHint: .isDirectory)
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let cache = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let appStore = try CoreDataAppStore(inMemory: true)
        let fileStore = AppFileStore(documentsDirectory: documents, cacheDirectory: cache)

        // 设备上仍登记着旧身份（DEF/OLD-PROFILE），等待新进程结算推进。
        let oldExpiry = Date(timeIntervalSince1970: 1_700_000_000)
        let sealID = UUID()
        let ipaRelativePath = "Apps/\(sealID.uuidString)/Original.ipa"
        let ipaURL = documents.appending(path: ipaRelativePath)
        try FileManager.default.createDirectory(at: ipaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("seal".utf8).write(to: ipaURL)
        try await appStore.save(AppRecord(
            id: sealID,
            originalBundleIdentifier: "com.mjorb.seal",
            mappedBundleIdentifier: "com.mjorb.seal",
            name: "Seal",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            expiryDate: oldExpiry,
            signingTeamID: "TEAM",
            certificateSerialNumber: "DEF",
            provisioningProfileUUID: "OLD-PROFILE",
            provisioningProfileExpirationDate: oldExpiry,
            ipaRelativePath: ipaRelativePath,
            signedArtifactStatus: .awaitingVerification,
            isSeal: true,
            importedAt: .distantPast
        ))

        let transactionStore = SelfReplacementTransactionStore(
            fileURL: root.appending(path: "SelfSigningHandoff.json")
        )
        let running = InstalledIdentity.fixtureMain(
            bundleIdentifier: "com.mjorb.seal",
            teamIdentifier: candidateTeam,
            profileUUID: candidateProfileUUID,
            signerSerialNumber: candidateSigner
        )
        let transaction = SelfReplacementTransaction.make(
            id: UUID(),
            accountID: UUID(),
            preparedProcessID: UUID(),
            installedBefore: .unknown(bundleIdentifier: "com.mjorb.seal"),
            candidate: .matching(running, transactionID: UUID()),
            signedIPARelativePath: "Apps/Seal/Signed.ipa"
        )
        _ = try await transactionStore.create(transaction)

        let replacement = StubSelfReplacement(action: action, store: transactionStore)
        await replacement.setSettlePayload(SettledSelfReplacement(
            transactionID: transaction.id,
            installedIdentity: running,
            mainBundleIdentifier: "com.mjorb.seal",
            mainProfileUUID: candidateProfileUUID,
            installedIdentityReadAt: Date()
        ))
        let profileCleaner = RecordingProfileCleaner(appStore: appStore)
        let registrar = SelfAppRegistrar(
            metadata: SelfAppMetadata(
                bundleURL: root.appending(path: "Running.app"),
                bundleIdentifier: "com.mjorb.seal",
                originalBundleIdentifier: nil,
                name: "Seal",
                version: "1.0",
                buildNumber: "1",
                iconData: nil,
                expirationDate: candidateExpiry,
                signingTeamIdentifier: candidateTeam,
                signingApplicationIdentifier: nil,
                provisioningProfileUUID: candidateProfileUUID,
                certificateSerialNumbers: [candidateSigner]
            ),
            appStore: appStore,
            accountRepository: HandoffEmptyAccountRepository(),
            fileStore: fileStore,
            selfReplacement: replacement,
            profileCleaner: profileCleaner
        )
        return ReplacementRegistrarFixture(
            root: root,
            registrar: registrar,
            appStore: appStore,
            transactionStore: transactionStore,
            replacement: replacement,
            profileCleaner: profileCleaner
        )
    }
}
