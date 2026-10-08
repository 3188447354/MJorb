import Foundation
import Testing
@testable import Seal

struct SelfAppRegistrarTests {
    @Test
    func preservesTheFirstOriginalBundleIdentifierAcrossSelfUpdates() {
        #expect(
            SelfAppBundleIdentity.originalBundleIdentifier(
                currentBundleIdentifier: "com.mjorb.seal.apps.renewed",
                declaredOriginalBundleIdentifier: "com.mjorb.seal",
                existingOriginalBundleIdentifier: "com.mjorb.seal"
            ) == "com.mjorb.seal"
        )
    }

    @Test
    func usesEmbeddedOriginalBundleIdentifierAfterTheAppContainerChanges() {
        #expect(
            SelfAppBundleIdentity.originalBundleIdentifier(
                currentBundleIdentifier: "com.mjorb.seal.apps.renewed",
                declaredOriginalBundleIdentifier: "com.mjorb.seal",
                existingOriginalBundleIdentifier: nil
            ) == "com.mjorb.seal"
        )
    }

    @Test
    func usesTheCurrentIdentifierOnlyForFirstRegistration() {
        #expect(
            SelfAppBundleIdentity.originalBundleIdentifier(
                currentBundleIdentifier: "com.mjorb.seal",
                declaredOriginalBundleIdentifier: nil,
                existingOriginalBundleIdentifier: nil
            ) == "com.mjorb.seal"
        )
    }

    @Test
    func matchesTheInstalledProfileTeamToTheStoredAccount() {
        let expectedID = UUID()
        let accounts = [
            AppleAccountRecord(
                maskedEmail: "other@icloud.com",
                accountIdentifier: "other",
                teamID: "OTHERTEAM",
                teamName: "Other",
                lastVerifiedAt: .distantPast
            ),
            AppleAccountRecord(
                id: expectedID,
                maskedEmail: "te***@example.com",
                accountIdentifier: "current",
                teamID: "TTEAM000001",
                teamName: "Current",
                lastVerifiedAt: .now
            )
        ]

        #expect(
            SelfAppAccountBinding.matchedAccountID(
                teamIdentifier: "tteam000001",
                accounts: accounts
            ) == expectedID
        )
    }

    @Test
    func profileTeamWithoutSavedMatchDoesNotReuseStaleAccount() {
        let staleAccountID = UUID()

        #expect(
            SelfAppAccountBinding.resolvedAccountID(
                teamIdentifier: "CURRENTTEAM",
                accounts: [],
                fallbackAccountID: staleAccountID
            ) == nil
        )
    }

    @Test
    func missingProfileTeamFallsBackToStoredAccount() {
        let storedAccountID = UUID()

        #expect(
            SelfAppAccountBinding.resolvedAccountID(
                teamIdentifier: nil,
                accounts: [],
                fallbackAccountID: storedAccountID
            ) == storedAccountID
        )
    }

    @Test
    func doesNotReuseAnUnrelatedLegacySealRecord() {
        let stale = AppRecord(
            originalBundleIdentifier: "com.mjorb.seal",
            mappedBundleIdentifier: "com.mjorb.seal.dmj",
            name: "Seal",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            accountID: UUID(),
            ipaRelativePath: "Apps/stale.ipa",
            preferredBundleIdentifier: "com.mjorb.seal.dmj",
            isSeal: true,
            importedAt: .distantPast
        )

        #expect(
            SelfAppRecordSelection.preferredExistingSealRecord(
                in: [stale],
                currentBundleIdentifier: "com.mjorb.seal.tteam000001"
            ) == nil
        )
    }

    @Test
    func originalIdentifierDoesNotOverrideAStaleInstalledIdentifier() {
        let stale = AppRecord(
            originalBundleIdentifier: "com.mjorb.seal",
            mappedBundleIdentifier: "com.mjorb.seal.dmj",
            name: "Seal",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            accountID: UUID(),
            ipaRelativePath: "Apps/stale.ipa",
            preferredBundleIdentifier: "com.mjorb.seal.dmj",
            isSeal: true,
            importedAt: .distantPast
        )

        #expect(
            SelfAppRecordSelection.preferredExistingSealRecord(
                in: [stale],
                currentBundleIdentifier: "com.mjorb.seal"
            ) == nil
        )
    }

    @Test
    func reusesTheRecordThatMatchesTheCurrentInstalledBundleIdentifier() {
        let matching = AppRecord(
            originalBundleIdentifier: "com.mjorb.seal",
            mappedBundleIdentifier: "com.mjorb.seal.tteam000001",
            name: "Seal",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            accountID: UUID(),
            ipaRelativePath: "Apps/current.ipa",
            preferredBundleIdentifier: "com.mjorb.seal.tteam000001",
            isSeal: true,
            importedAt: .now
        )

        #expect(
            SelfAppRecordSelection.preferredExistingSealRecord(
                in: [matching],
                currentBundleIdentifier: "com.mjorb.seal.tteam000001"
            )?.id == matching.id
        )
    }

    @Test
    func doesNotOverwriteAnImportedSealUpdateSourceDuringStartupSync() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SealSelfRegistrar-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let cache = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let appStore = try CoreDataAppStore(inMemory: true)
        let fileStore = AppFileStore(documentsDirectory: documents, cacheDirectory: cache)
        let sealID = UUID()
        let importedPath = "Apps/\(sealID.uuidString)/Original.ipa"
        let importedURL = documents.appending(path: importedPath)
        try FileManager.default.createDirectory(
            at: importedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("imported-seal-update".utf8).write(to: importedURL)
        let pendingUpdate = AppRecord(
            id: sealID,
            originalBundleIdentifier: "com.mjorb.seal",
            mappedBundleIdentifier: "com.mjorb.seal.TEAM000001",
            name: "Seal",
            version: "2.0",
            buildNumber: "82",
            size: 100,
            state: .installed,
            accountID: UUID(),
            ipaRelativePath: importedPath,
            preferredBundleIdentifier: "com.mjorb.seal.TEAM000001",
            hasPendingSelfUpdateSource: true,
            isSeal: true,
            isPinned: true,
            importedAt: .distantPast
        )
        try await appStore.save(pendingUpdate)
        let currentBundle = root.appending(path: "CurrentSeal.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: currentBundle, withIntermediateDirectories: true)
        let registrar = SelfAppRegistrar(
            metadata: SelfAppMetadata(
                bundleURL: currentBundle,
                bundleIdentifier: "com.mjorb.seal.TEAM000001",
                originalBundleIdentifier: "com.mjorb.seal",
                name: "Seal",
                version: "1.0",
                buildNumber: "1",
                iconData: nil,
                expirationDate: nil,
                signingTeamIdentifier: nil,
                signingApplicationIdentifier: nil
            ),
            appStore: appStore,
            accountRepository: EmptyAccountRepository(),
            fileStore: fileStore
        )

        try await registrar.ensureRegistered()

        let records = try await appStore.fetchAll()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.id == sealID)
        #expect(record.version == "2.0")
        #expect(record.hasPendingSelfUpdateSource)
        #expect(try Data(contentsOf: importedURL) == Data("imported-seal-update".utf8))
    }

    /// R07：同版本续签会换掉 profile（新 UUID、新有效期）但**版本号不变**。
    /// 只比版本号就会漏掉结算，数据库里的有效期会永远停在旧值。
    @Test
    func sameVersionRenewalSettlesProfileIdentityFromTheRunningBundle() async throws {
        let fixture = try makeSealFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldExpiry = Date(timeIntervalSince1970: 1_700_000_000)
        let newExpiry = Date(timeIntervalSince1970: 1_750_000_000)
        try await fixture.appStore.save(
            makeSealRecord(
                fixture,
                expiry: oldExpiry,
                profileUUID: "OLD-PROFILE",
                profileName: "Seal"
            )
        )

        let registrar = makeRegistrar(
            fixture,
            metadata: SelfAppMetadata(
                bundleURL: fixture.currentBundle,
                bundleIdentifier: "com.mjorb.seal",
                originalBundleIdentifier: "com.mjorb.seal",
                name: "Seal",
                version: "1.0",            // ← 版本号与记录一致
                buildNumber: "1",
                iconData: nil,
                expirationDate: newExpiry,
                signingTeamIdentifier: nil,
                signingApplicationIdentifier: nil,
                provisioningProfileUUID: "NEW-PROFILE",
                provisioningProfileName: "Seal Renewed",
                provisioningProfileCreationDate: nil
            )
        )

        try await registrar.ensureRegistered()

        let updated = try #require(try await fixture.appStore.fetchAll().first)
        #expect(updated.provisioningProfileUUID == "NEW-PROFILE")
        #expect(updated.provisioningProfileName == "Seal Renewed")
        #expect(updated.expiryDate == newExpiry)
        #expect(updated.provisioningProfileExpirationDate == newExpiry)
    }

    /// R07 回归：自更新安装失败（或进程在安装中被系统杀掉）时，记录里那份
    /// 「安装前乐观写入」的新有效期必须被纠正回**运行中旧包**的真实有效期，
    /// 否则 UI 会显示设备上并不存在的到期日，用户直到应用被吊销都收不到提醒。
    @Test
    func failedSelfUpdateRollsBackToTheRunningBundleProfile() async throws {
        let fixture = try makeSealFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runningExpiry = Date(timeIntervalSince1970: 1_700_000_000)
        let optimisticallyWrittenExpiry = Date(timeIntervalSince1970: 1_750_000_000)
        // 记录里是「以为装上了」的新值……
        try await fixture.appStore.save(
            makeSealRecord(
                fixture,
                expiry: optimisticallyWrittenExpiry,
                profileUUID: "NEW-PROFILE",
                profileName: "Seal Renewed"
            )
        )

        // ……但运行中的 Bundle 仍是旧包（profile 是旧的）。
        let registrar = makeRegistrar(
            fixture,
            metadata: SelfAppMetadata(
                bundleURL: fixture.currentBundle,
                bundleIdentifier: "com.mjorb.seal",
                originalBundleIdentifier: "com.mjorb.seal",
                name: "Seal",
                version: "1.0",
                buildNumber: "1",
                iconData: nil,
                expirationDate: runningExpiry,
                signingTeamIdentifier: nil,
                signingApplicationIdentifier: nil,
                provisioningProfileUUID: "OLD-PROFILE",
                provisioningProfileName: "Seal",
                provisioningProfileCreationDate: nil
            )
        )

        try await registrar.ensureRegistered()

        let updated = try #require(try await fixture.appStore.fetchAll().first)
        #expect(updated.provisioningProfileUUID == "OLD-PROFILE", "必须回滚到运行中包的真实 profile")
        #expect(updated.provisioningProfileName == "Seal")
        #expect(updated.expiryDate == runningExpiry)
        #expect(updated.provisioningProfileExpirationDate == runningExpiry)
    }

    /// 运行包读不到 profile 身份时（解析失败）不得凭空改写已有值 —— 只保留 Team/账号回补。
    @Test
    func missingProfileIdentityLeavesStoredProfileFieldsAlone() async throws {
        let fixture = try makeSealFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let storedExpiry = Date(timeIntervalSince1970: 1_700_000_000)
        try await fixture.appStore.save(
            makeSealRecord(
                fixture,
                expiry: storedExpiry,
                profileUUID: "KEEP-ME",
                profileName: "Seal"
            )
        )

        let registrar = makeRegistrar(
            fixture,
            metadata: SelfAppMetadata(
                bundleURL: fixture.currentBundle,
                bundleIdentifier: "com.mjorb.seal",
                originalBundleIdentifier: "com.mjorb.seal",
                name: "Seal",
                version: "1.0",
                buildNumber: "1",
                iconData: nil,
                expirationDate: nil,
                signingTeamIdentifier: nil,
                signingApplicationIdentifier: nil
            )
        )

        try await registrar.ensureRegistered()

        let updated = try #require(try await fixture.appStore.fetchAll().first)
        #expect(updated.provisioningProfileUUID == "KEEP-ME")
        #expect(updated.expiryDate == storedExpiry)
    }

    /// 2026-10-02：自替换结算成功后必须清除待安装源指纹（自愈）。
    ///
    /// 指纹是导入 Seal 自身 IPA 时写入的；不清掉的话，同版本导入的包会在**每次**
    /// 续签时都被 `hasPendingUpdateSource` 判成「有待安装更新」⇒ 每次续签都完整重装
    /// —— 1.3.17「续签全都要重装」的坑会回来。
    ///
    /// 注意 `hasPendingSelfUpdateSource` 在这里刻意不清：自替换走不到
    /// `SigningCoordinator` 的普通安装路径，那个标志的语义是「导入过自更新源」，
    /// 由启动时的待安装分支按版本/文件存在性解读。
    @Test
    func successfulSelfReplacementSettlementClearsPendingUpdateSourceFingerprint() async throws {
        let fixture = try makeSealFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var seal = makeSealRecord(
            fixture,
            expiry: Date(timeIntervalSince1970: 1_700_000_000),
            profileUUID: "OLD-PROFILE",
            profileName: "Seal"
        )
        seal.hasPendingSelfUpdateSource = true
        seal.pendingUpdateSourceFingerprint = "sha256-of-imported-update"
        try await fixture.appStore.save(seal)

        let newExpiry = Date(timeIntervalSince1970: 1_750_000_000)
        let installedIdentity = InstalledIdentity(
            bundleURL: fixture.currentBundle,
            version: "1.0",
            buildNumber: "1",
            targets: [
                SignedTargetIdentity(
                    kind: .mainApp,
                    bundleIdentifier: "com.mjorb.seal",
                    teamIdentifier: "TEAM000001",
                    applicationIdentifier: "TEAM000001.com.mjorb.seal",
                    profileUUID: "NEW-PROFILE",
                    profileExpirationDate: newExpiry,
                    signerSerialNumber: "SERIAL",
                    signerCertificateSHA256: "CERTSHA",
                    status: .complete
                )
            ],
            readErrors: []
        )
        let registrar = SelfAppRegistrar(
            metadata: SelfAppMetadata(
                bundleURL: fixture.currentBundle,
                bundleIdentifier: "com.mjorb.seal",
                originalBundleIdentifier: "com.mjorb.seal",
                name: "Seal",
                version: "1.0",
                buildNumber: "1",
                iconData: nil,
                expirationDate: newExpiry,
                signingTeamIdentifier: "TEAM000001",
                signingApplicationIdentifier: nil,
                provisioningProfileUUID: "NEW-PROFILE",
                provisioningProfileName: "Seal Renewed",
                provisioningProfileCreationDate: nil
            ),
            appStore: fixture.appStore,
            accountRepository: EmptyAccountRepository(),
            fileStore: fixture.fileStore,
            selfReplacement: FakeSelfReplacing(
                reconcileAction: .settle,
                settled: SettledSelfReplacement(
                    transactionID: UUID(),
                    installedIdentity: installedIdentity,
                    mainBundleIdentifier: "com.mjorb.seal",
                    mainProfileUUID: "NEW-PROFILE",
                    installedIdentityReadAt: Date()
                )
            )
        )

        try await registrar.ensureRegistered()

        let updated = try #require(try await fixture.appStore.fetchAll().first)
        // 指纹清掉 ⇒ 下一次续签准入不再把它当成待安装更新（自愈）。
        #expect(updated.pendingUpdateSourceFingerprint == nil)
        // 结算确认的真实身份仍然写入。
        #expect(updated.provisioningProfileUUID == "NEW-PROFILE")
        #expect(updated.expiryDate == newExpiry)
        // `hasPendingSelfUpdateSource` 刻意保留（语义是「导入过自更新源」）。
        #expect(updated.hasPendingSelfUpdateSource)
    }

    // MARK: - 夹具

    private struct SealFixture {
        let root: URL
        let sealID: UUID
        let currentBundle: URL
        let appStore: CoreDataAppStore
        let fileStore: AppFileStore
    }

    private func makeSealFixture() throws -> SealFixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SealSelfRegistrar-\(UUID().uuidString)", directoryHint: .isDirectory)
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let cache = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let sealID = UUID()
        // 同版本分支要求原始 IPA 仍在（否则会走重打包路径）
        let ipaURL = documents.appending(path: "Apps/\(sealID.uuidString)/Original.ipa")
        try FileManager.default.createDirectory(
            at: ipaURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("seal".utf8).write(to: ipaURL)
        let currentBundle = root.appending(path: "CurrentSeal.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: currentBundle, withIntermediateDirectories: true)
        return SealFixture(
            root: root,
            sealID: sealID,
            currentBundle: currentBundle,
            appStore: try CoreDataAppStore(inMemory: true),
            fileStore: AppFileStore(documentsDirectory: documents, cacheDirectory: cache)
        )
    }

    private func makeSealRecord(
        _ fixture: SealFixture,
        expiry: Date,
        profileUUID: String,
        profileName: String
    ) -> AppRecord {
        AppRecord(
            id: fixture.sealID,
            originalBundleIdentifier: "com.mjorb.seal",
            name: "Seal",
            version: "1.0",
            buildNumber: "1",
            size: 100,
            state: .installed,
            expiryDate: expiry,
            provisioningProfileUUID: profileUUID,
            provisioningProfileName: profileName,
            provisioningProfileExpirationDate: expiry,
            ipaRelativePath: "Apps/\(fixture.sealID.uuidString)/Original.ipa",
            isSeal: true,
            importedAt: .distantPast
        )
    }

    private func makeRegistrar(
        _ fixture: SealFixture,
        metadata: SelfAppMetadata
    ) -> SelfAppRegistrar {
        SelfAppRegistrar(
            metadata: metadata,
            appStore: fixture.appStore,
            accountRepository: EmptyAccountRepository(),
            fileStore: fixture.fileStore
        )
    }
}

private actor EmptyAccountRepository: AccountRepository {
    func fetchAll() throws -> [AppleAccountRecord] { [] }
    func save(_ account: AppleAccountRecord) throws {}
    func delete(id: UUID) throws {}
}

/// 只为结算测试服务的假自替换协调器：`reconcileAtLaunch` 返回预设动作，
/// `settle` 返回预设的结算结果，其余方法测试里用不到。
private actor FakeSelfReplacing: SelfReplacing {
    let reconcileAction: SelfReplacementReconcileAction
    let settled: SettledSelfReplacement

    init(
        reconcileAction: SelfReplacementReconcileAction,
        settled: SettledSelfReplacement
    ) {
        self.reconcileAction = reconcileAction
        self.settled = settled
    }

    func prepare(
        app: AppRecord,
        accountID: UUID,
        signedIPARelativePath: String,
        preloadedData: Data? = nil
    ) async throws -> SelfReplacementTransaction {
        throw SelfReplacementFailure.bundleShapeChanged
    }

    func submitPrepared(
        transactionID: UUID,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {}

    func dropPreparedData(transactionID: UUID) async {}

    func reconcileAtLaunch() async throws -> SelfReplacementReconcileAction {
        reconcileAction
    }

    func settle() async throws -> SettledSelfReplacement {
        settled
    }

    func closeAsNotInstalled() async throws {}

    func requireRecovery(reason: String) async throws {}

    func finishCleanup(_ summary: ProfileCleanupSummary) async throws {}
}
