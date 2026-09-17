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
                provisioningProfileUUID: "OLD", certificateSerialNumbers: ["DEF"],
                installedIdentity: .fixtureMain(
                    bundleIdentifier: "com.mjorb.seal",
                    teamIdentifier: "TEAM",
                    profileUUID: "OLD",
                    signerSerialNumber: "DEF"
                )
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

    /// 结算清理的保留集合**只有 Seal 自己一个条目** ⇒ 其它 App 的 Bundle ID 全是候选。
    /// 主 App 靠设备端核验能救回来，**扩展救不回来**（扩展不是独立安装的 App，
    /// `isAppInstalled` 恒为 `false`）—— 2026-09-17 真机（构建 95）就是这么丢掉
    /// LiveContainer 三个扩展的 profile 的：`候选 4，回收 3，已装保留 1`。
    ///
    /// 所以 `protectedBundleIDs` 是这条路径**唯一**能保护扩展的东西，必须真的传下去。
    @Test
    func settleCleanupCarriesProtectedBundleIDsForOtherAppsExtensions() async throws {
        let fixture = try await ReplacementRegistrarFixture.make(action: .settle)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let otherMain = "com.example.livecontainer.seal.TEAM"
        let otherExtension = "com.example.livecontainer.seal.TEAM.ShareExtension"
        try await fixture.appStore.save(AppRecord(
            id: UUID(),
            originalBundleIdentifier: "com.example.livecontainer",
            mappedBundleIdentifier: otherMain,
            name: "另一个 App",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            provisioningProfileUUID: "OTHER-PROFILE",
            ipaRelativePath: "Apps/Other/Original.ipa",
            signedArtifactStatus: .installed,
            importedAt: .distantPast,
            extensions: [
                AppExtensionRecord(
                    name: "ShareExtension",
                    originalBundleIdentifier: "com.example.ShareExtension",
                    mappedBundleIdentifier: otherExtension,
                    provisioningProfileUUID: "OTHER-EXT-PROFILE"
                )
            ]
        ))

        try await fixture.registrar.ensureRegistered()

        let requests = await fixture.profileCleaner.requests
        #expect(requests.count == 1)
        let protected = requests.first?.protectedBundleIDs ?? []
        // 其它 App 的扩展必须在受保护集合里 —— 这是它唯一的保护。
        let extensionProtected = protected.contains(otherExtension)
        #expect(extensionProtected == true)
        let mainProtected = protected.contains(otherMain)
        #expect(mainProtected == true)
    }

    /// 自替换结算清理是**唯一**会回收 Seal 自己那份 profile 堆积的路径（Seal 的自更新不走
    /// `installSignedIPA`，所以「安装后旧描述文件清理」根本轮不到它）。而它原先只把摘要写进
    /// **事务审计** —— 排障时能拿到的只有日志，于是真机上 Seal 堆了 16 份旧 profile，
    /// 日志里却查不出这条清理到底跑没跑、是不是被判成了身份已变化。
    ///
    /// 这里守的是「日志真的落下来了」：源码断言只能证明调用了 `logStore?.append`，
    /// 证明不了消息内容真的进得去（比如 `logStore` 没被注入、或消息被脱敏吃掉）。
    @Test
    func confirmedReplacementLogsCleanupSummary() async throws {
        let logDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SealCleanupLog-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let logStore = SealLogStore(
            fileURL: logDirectory.appending(path: "Logs.json"),
            fileProtector: MarkerFileProtector()
        )
        let fixture = try await ReplacementRegistrarFixture.make(action: .settle, logStore: logStore)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try await fixture.registrar.ensureRegistered()

        let entries = try await logStore.entries()
        // 判定写在 `#expect` 外面：`#expect` 是宏，会把表达式重写成闭包、子表达式绑成 `$0`，
        // 把 `contains(where:)` 这类带闭包的调用塞进去容易被改写出意料之外的形状。
        let logged = entries.contains { $0.message.hasPrefix("自替换结算清理：") }
        #expect(logged, "结算清理必须在日志里留痕，否则 Seal 自己的 profile 堆积无法归因")
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
        // 没有「已定论的结果」可传 ⇒ 仍然按「结果未知」处理（这是正确的保守行为）
        #expect(try await restarted.recoverInterrupted().downgraded == 1)
        let outstanding = try await restarted.outstanding()
        #expect(outstanding.count == 1)
        #expect(outstanding.first?.state == .unknown)
        #expect(outstanding.first?.id == item.id)
    }

    @Test
    func unreadableIdentityNeverFallsBackToProfileAuthorizedSerial() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SealUnreadableIdentity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let cache = root.appending(path: "Caches", directoryHint: .isDirectory)
        let id = UUID()
        let relativePath = "Apps/\(id.uuidString)/Original.ipa"
        let ipaURL = documents.appending(path: relativePath)
        try FileManager.default.createDirectory(at: ipaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("seal".utf8).write(to: ipaURL)
        let appStore = try CoreDataAppStore(inMemory: true)
        let fileStore = AppFileStore(documentsDirectory: documents, cacheDirectory: cache)
        let expiry = Date(timeIntervalSince1970: 1_700_000_000)
        try await appStore.save(AppRecord(
            id: id, originalBundleIdentifier: "com.mjorb.seal",
            mappedBundleIdentifier: "com.mjorb.seal", name: "Seal", version: "1.0",
            buildNumber: "1", size: 1, state: .installed, expiryDate: expiry,
            signingTeamID: "TEAM", certificateSerialNumber: "DEF",
            provisioningProfileUUID: "OLD", provisioningProfileExpirationDate: expiry,
            ipaRelativePath: relativePath, isSeal: true, importedAt: .distantPast
        ))
        let registrar = SelfAppRegistrar(
            metadata: SelfAppMetadata(
                bundleURL: root.appending(path: "Running.app"), bundleIdentifier: "com.mjorb.seal",
                originalBundleIdentifier: nil, name: "Seal", version: "1.0", buildNumber: "1", iconData: nil,
                expirationDate: expiry, signingTeamIdentifier: "TEAM", signingApplicationIdentifier: nil,
                provisioningProfileUUID: "OLD", certificateSerialNumbers: ["PROFILE-ONLY"]
            ),
            appStore: appStore, accountRepository: HandoffEmptyAccountRepository(), fileStore: fileStore
        )

        try await registrar.ensureRegistered()

        // 真实 CMS 身份读取失败时，只能保留既有记录，绝不能把描述文件授权证书当成实际签名者。
        let updated = try #require(try await appStore.fetchAll().first)
        #expect(updated.certificateSerialNumber == "DEF")
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

    static func make(
        action: SelfReplacementReconcileAction,
        logStore: SealLogStore? = nil
    ) async throws -> ReplacementRegistrarFixture {
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
                certificateSerialNumbers: [candidateSigner],
                installedIdentity: running
            ),
            appStore: appStore,
            accountRepository: HandoffEmptyAccountRepository(),
            fileStore: fileStore,
            selfReplacement: replacement,
            profileCleaner: profileCleaner,
            logStore: logStore
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
