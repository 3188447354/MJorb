import Foundation
import Testing
@testable import Seal

struct ImportWorkflowTests {
    @Test
    func preparesParsedDraftForConfirmation() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let source = try IPAArchiveFixture.make(includeShareExtension: true)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

        let workflow = makeWorkflow(environment: environment)
        await workflow.prepare(sourceURL: source)

        let draft = try requireDraft(await workflow.state)
        #expect(draft.parsedIPA.name == "Demo")
        #expect(draft.parsedIPA.extensions.count == 1)
        #expect(FileManager.default.fileExists(atPath: draft.stagedIPA.url.path))
    }

    @Test
    func confirmationCommitsFilesAndRecord() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let source = try IPAArchiveFixture.make()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let appID = UUID()
        let workflow = makeWorkflow(environment: environment, appID: appID)

        await workflow.prepare(sourceURL: source)
        await workflow.confirm()

        let record = try requireCompleted(await workflow.state)
        #expect(record.id == appID)
        #expect(record.state == .preflightPassed)
        #expect(record.ipaRelativePath == "Apps/\(appID.uuidString)/Original.ipa")
        #expect(try await environment.appStore.fetchAll() == [record])
        #expect(FileManager.default.fileExists(
            atPath: environment.documents.appending(path: record.ipaRelativePath).path
        ))
    }

    @Test
    func cancellationRemovesPreparedDraft() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let source = try IPAArchiveFixture.make()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let workflow = makeWorkflow(environment: environment)

        await workflow.prepare(sourceURL: source)
        let draft = try requireDraft(await workflow.state)
        await workflow.cancel()

        #expect(await workflow.state == .idle)
        #expect(FileManager.default.fileExists(atPath: draft.stagedIPA.url.path) == false)
    }

    @Test
    func parserFailureCleansStagedFileAndKeepsRecoveryCopyShort() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let source = try IPAArchiveFixture.make(apps: [.init(malformedInfo: true)])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let workflow = makeWorkflow(environment: environment)

        await workflow.prepare(sourceURL: source)

        let failure = try requireFailure(await workflow.state)
        #expect(failure.code == "SEAL-IPA-102")
        #expect(failure.recovery == "选择其他 IPA")
        let temporaryRoot = environment.cache.appending(
            path: "Seal/Temp",
            directoryHint: .isDirectory
        )
        let remaining = try FileManager.default.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: nil
        )
        #expect(remaining.isEmpty)
    }

    @Test
    func persistenceFailureCanRetryWithoutReselectingIPA() async throws {
        let environment = try makeEnvironment(appStore: FailOnceAppStore())
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let source = try IPAArchiveFixture.make()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let appID = UUID()
        let workflow = makeWorkflow(environment: environment, appID: appID)

        await workflow.prepare(sourceURL: source)
        let draft = try requireDraft(await workflow.state)
        await workflow.confirm()
        let failure = try requireFailure(await workflow.state)
        #expect(failure.code == "SEAL-IPA-205")
        #expect(FileManager.default.fileExists(atPath: draft.stagedIPA.url.path))
        #expect(FileManager.default.fileExists(
            atPath: environment.documents
                .appending(path: "Apps/\(appID.uuidString)/Original.ipa")
                .path
        ) == false)

        await workflow.retry()

        _ = try requireCompleted(await workflow.state)
        let records = try await environment.appStore.fetchAll()
        #expect(records.count == 1)
        #expect(FileManager.default.fileExists(atPath: draft.stagedIPA.url.path) == false)
    }

    @Test
    func duplicateOriginalBundleIDCreatesIndependentCopies() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let oldID = UUID()
        let oldRecord = AppRecord(
            id: oldID,
            originalBundleIdentifier: "com.example.demo",
            name: "Old Demo",
            version: "0.9",
            buildNumber: "1",
            size: 10,
            state: .preflightPassed,
            ipaRelativePath: "Apps/\(oldID.uuidString)/Original.ipa",
            importedAt: Date(timeIntervalSince1970: 100)
        )
        let oldIPA = environment.documents.appending(path: oldRecord.ipaRelativePath)
        try FileManager.default.createDirectory(
            at: oldIPA.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: oldIPA)
        try await environment.appStore.save(oldRecord)
        let source = try IPAArchiveFixture.make()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let newID = UUID()
        let workflow = makeWorkflow(environment: environment, appID: newID)

        await workflow.prepare(sourceURL: source)
        await workflow.confirm()

        let records = try await environment.appStore.fetchAll()
        // 多副本设计：同一原始 Bundle ID 再次导入产生独立条目（可用不同 Bundle ID 签名并存），不替换旧记录
        #expect(records.count == 2)
        let imported = try requireCompleted(await workflow.state)
        #expect(imported.id == newID)
        #expect(imported.ipaRelativePath == "Apps/\(newID.uuidString)/Original.ipa")
        #expect(imported.name == "Demo")
        #expect(imported.state == .preflightPassed)
        // 旧记录与其原始文件原样保留，不被覆盖或删除
        let keptOld = try #require(records.first { $0.id == oldID })
        #expect(keptOld.ipaRelativePath == oldRecord.ipaRelativePath)
        #expect(FileManager.default.fileExists(atPath: oldIPA.path))
        #expect(try Data(contentsOf: oldIPA) == Data("old".utf8))
    }

    @Test
    func successfulSigningPreferencesAreInheritedByLaterImportOfSameOriginalBundleID() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let previousID = UUID()
        let previousIcon = Data("preferred-icon".utf8)
        let previousIconPath = try await environment.fileStore.storePreferredIcon(
            data: previousIcon,
            appID: previousID
        )
        let previous = AppRecord(
            id: previousID,
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: "com.example.demo.personal",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 10,
            state: .signed,
            accountID: UUID(),
            signingTeamID: "TEAM",
            certificateSerialNumber: "SERIAL",
            signedDeviceIdentifier: "DEVICE",
            provisioningProfileExpirationDate: Date(timeIntervalSince1970: 1_900_000_000),
            lastSignedAt: Date(timeIntervalSince1970: 1_800_000_000),
            removedExtensionBundleIdentifiers: ["com.example.demo.share"],
            ipaRelativePath: "Apps/\(previousID.uuidString)/Original.ipa",
            signedIPARelativePath: "Apps/\(previousID.uuidString)/Signed.ipa",
            signedIPASHA256: "abc",
            signedArtifactStatus: .available,
            preferredBundleIdentifier: "com.example.demo.personal",
            preferredDisplayName: "Demo Custom",
            preferredIconRelativePath: previousIconPath,
            importedAt: Date(timeIntervalSince1970: 100)
        )
        try await environment.appStore.save(previous)

        let source = try IPAArchiveFixture.make()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let newID = UUID()
        let workflow = makeWorkflow(environment: environment, appID: newID)
        await workflow.prepare(sourceURL: source)
        await workflow.confirm()

        let imported = try requireCompleted(await workflow.state)
        #expect(imported.id == newID)
        // 多副本设计：不继承上次签名的自定义 Bundle ID（回到原始，便于用新 Bundle ID 签出并存副本）
        #expect(imported.preferredBundleIdentifier == nil)
        // 但用户偏好（自定义显示名、移除的扩展、偏好图标）仍从最近签名记录继承
        #expect(imported.preferredDisplayName == "Demo Custom")
        #expect(imported.removedExtensionBundleIdentifiers == ["com.example.demo.share"])
        let inheritedIconPath = try #require(imported.preferredIconRelativePath)
        #expect(inheritedIconPath != previousIconPath)
        #expect(try await environment.fileStore.read(relativePath: inheritedIconPath) == previousIcon)
    }

    @Test
    func importingSealIPAUpdatesTheInstalledSealRecordInsteadOfCreatingADuplicate() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let sealID = UUID()
        let accountID = UUID()
        let previousOriginalPath = "Apps/\(sealID.uuidString)/Original.ipa"
        let installedSeal = AppRecord(
            id: sealID,
            originalBundleIdentifier: "com.mjorb.seal",
            mappedBundleIdentifier: "com.mjorb.seal.3432ZHJUF9",
            name: "Seal",
            version: "1.0",
            buildNumber: "1",
            size: 10,
            state: .installed,
            expiryDate: Date(timeIntervalSince1970: 1_800_000_000),
            accountID: accountID,
            signingTeamID: "3432ZHJUF9",
            certificateSerialNumber: "SERIAL",
            signedDeviceIdentifier: "DEVICE",
            provisioningProfileExpirationDate: Date(timeIntervalSince1970: 1_800_000_000),
            lastSignedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastInstalledAt: Date(timeIntervalSince1970: 1_700_000_100),
            ipaRelativePath: previousOriginalPath,
            signedIPARelativePath: "Apps/\(sealID.uuidString)/Signed.ipa",
            signedIPASHA256: "old-sha",
            signedArtifactStatus: .installed,
            preferredBundleIdentifier: "com.mjorb.seal.3432ZHJUF9",
            isSeal: true,
            isPinned: true,
            importedAt: Date(timeIntervalSince1970: 100)
        )
        let oldIPA = environment.documents.appending(path: previousOriginalPath)
        try FileManager.default.createDirectory(
            at: oldIPA.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old-seal".utf8).write(to: oldIPA)
        try await environment.appStore.save(installedSeal)

        let source = try IPAArchiveFixture.make(
            apps: [
                .init(
                    directoryName: "Seal.app",
                    bundleIdentifier: "com.mjorb.seal",
                    name: "Seal",
                    version: "2.0",
                    buildNumber: "82"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let workflow = makeWorkflow(environment: environment, appID: UUID())

        await workflow.prepare(sourceURL: source)
        await workflow.confirm()

        let imported = try requireCompleted(await workflow.state)
        let records = try await environment.appStore.fetchAll()
        #expect(records.count == 1)
        #expect(imported.id == sealID)
        #expect(imported.isSeal)
        #expect(imported.state == .installed)
        #expect(imported.version == "2.0")
        #expect(imported.buildNumber == "82")
        #expect(imported.accountID == accountID)
        #expect(imported.signingTeamID == "3432ZHJUF9")
        #expect(imported.certificateSerialNumber == "SERIAL")
        #expect(imported.signedDeviceIdentifier == "DEVICE")
        #expect(imported.lastInstalledAt == installedSeal.lastInstalledAt)
        #expect(imported.signedIPARelativePath == nil)
        #expect(imported.signedIPASHA256 == nil)
        #expect(imported.signedArtifactStatus == nil)
        #expect(imported.hasPendingSelfUpdateSource)
        #expect(imported.ipaRelativePath == previousOriginalPath)
        #expect(FileManager.default.fileExists(atPath: oldIPA.path))
        #expect(try Data(contentsOf: oldIPA) != Data("old-seal".utf8))
    }

    private func makeWorkflow(
        environment: Environment,
        appID: UUID = UUID(),
        runningSealBundleIdentifier: String? = nil
    ) -> ImportWorkflow {
        ImportWorkflow(
            parser: IPAParserService(),
            fileStore: environment.fileStore,
            appStore: environment.appStore,
            runningSealBundleIdentifier: runningSealBundleIdentifier,
            now: { Date(timeIntervalSince1970: 1_750_000_000) },
            makeID: { appID }
        )
    }

    private func makeEnvironment(
        appStore: (any AppStore)? = nil
    ) throws -> Environment {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SealWorkflowTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let cache = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let resolvedAppStore: any AppStore
        if let appStore {
            resolvedAppStore = appStore
        } else {
            resolvedAppStore = try CoreDataAppStore(inMemory: true)
        }

        return Environment(
            root: root,
            documents: documents,
            cache: cache,
            fileStore: AppFileStore(
                documentsDirectory: documents,
                cacheDirectory: cache
            ),
            appStore: resolvedAppStore
        )
    }

    private func requireDraft(
        _ state: ImportWorkflowState,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ImportDraft {
        guard case .awaitingConfirmation(let draft) = state else {
            Issue.record("Expected confirmation state, got \(state).", sourceLocation: sourceLocation)
            throw TestFailure.unexpectedState
        }
        return draft
    }

    private func requireCompleted(
        _ state: ImportWorkflowState,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> AppRecord {
        guard case .completed(let record) = state else {
            Issue.record("Expected completed state, got \(state).", sourceLocation: sourceLocation)
            throw TestFailure.unexpectedState
        }
        return record
    }

    private func requireFailure(
        _ state: ImportWorkflowState,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ImportFailure {
        guard case .failed(let failure) = state else {
            Issue.record("Expected failed state, got \(state).", sourceLocation: sourceLocation)
            throw TestFailure.unexpectedState
        }
        return failure
    }
}

private extension ImportWorkflowTests {
    struct Environment {
        let root: URL
        let documents: URL
        let cache: URL
        let fileStore: AppFileStore
        let appStore: any AppStore
    }

    enum TestFailure: Error {
        case unexpectedState
    }
}

// MARK: - 覆盖更新：导入新版 → 覆盖安装已安装应用（2026-09-25 用户反馈）

extension ImportWorkflowTests {
    /// 用户报「新导入的话就在待签页，覆盖更新安装就到已签名」。
    /// 覆盖更新必须**复用已安装记录**（同 id / 同签名身份）并**清空旧版签名产物**：
    /// 身份变了 installd 会并存第二个 App；旧签名产物留着会让「复用已签名包直接安装」
    /// 把**旧版本**装回设备（用户会以为「更新没生效」）。
    @Test
    func overwriteUpdateReusesInstalledRecordIdentityAndClearsSignedArtifacts() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let installedID = UUID()
        let accountID = UUID()
        let originalPath = "Apps/\(installedID.uuidString)/Original.ipa"
        let installed = AppRecord(
            id: installedID,
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: "com.example.demo.3432ZHJUF9",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 10,
            state: .installed,
            expiryDate: Date(timeIntervalSince1970: 1_800_000_000),
            accountID: accountID,
            signingTeamID: "3432ZHJUF9",
            certificateSerialNumber: "SERIAL",
            signedDeviceIdentifier: "DEVICE",
            provisioningProfileExpirationDate: Date(timeIntervalSince1970: 1_800_000_000),
            lastSignedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastInstalledAt: Date(timeIntervalSince1970: 1_700_000_100),
            ipaRelativePath: originalPath,
            signedIPARelativePath: "Apps/\(installedID.uuidString)/Signed.ipa",
            signedIPASHA256: "old-sha",
            signedArtifactStatus: .installed,
            preferredBundleIdentifier: "com.example.demo.3432ZHJUF9",
            importedAt: Date(timeIntervalSince1970: 100)
        )
        let oldIPA = environment.documents.appending(path: originalPath)
        try FileManager.default.createDirectory(
            at: oldIPA.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: oldIPA)
        try await environment.appStore.save(installed)

        let source = try IPAArchiveFixture.make()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let draftAppID = UUID()
        let workflow = makeWorkflow(environment: environment, appID: draftAppID)

        await workflow.prepare(sourceURL: source)
        await workflow.confirm(target: .replaceInstalled(appID: installedID))

        let updated = try requireCompleted(await workflow.state)
        let records = try await environment.appStore.fetchAll()
        // 只留一条记录：覆盖更新复用已安装记录，不新建
        #expect(records.count == 1)
        #expect(updated.id == installedID)
        #expect(updated.version == "1.2.3")
        #expect(updated.state == .installed)
        #expect(updated.belongsInInstalledList)
        // 签名身份必须保留：换了身份 installd 就会并存第二个 App
        #expect(updated.mappedBundleIdentifier == "com.example.demo.3432ZHJUF9")
        #expect(updated.accountID == accountID)
        #expect(updated.signingTeamID == "3432ZHJUF9")
        #expect(updated.certificateSerialNumber == "SERIAL")
        #expect(updated.signedDeviceIdentifier == "DEVICE")
        #expect(updated.lastInstalledAt == installed.lastInstalledAt)
        // 旧版签名产物必须清空
        #expect(updated.signedIPARelativePath == nil)
        #expect(updated.signedIPASHA256 == nil)
        #expect(updated.signedArtifactStatus == nil)
        #expect(updated.hasPendingSelfUpdateSource)
        // 文件目录键必须与记录 id 一致：AppFileStore 用 appID 同时决定目录名与相对路径，
        // 两者不一致时签名阶段会去一个不存在的目录取包（覆盖后必然失败）。
        #expect(updated.ipaRelativePath == originalPath)
        #expect(FileManager.default.fileExists(atPath: oldIPA.path))
        #expect(try Data(contentsOf: oldIPA) != Data("old".utf8))
        // 草稿自己的 appID 不该在磁盘上留下任何目录
        #expect(FileManager.default.fileExists(
            atPath: environment.documents.appending(path: "Apps/\(draftAppID.uuidString)").path
        ) == false)
    }

    /// 复核不过必须**安全回落**成新建，绝不覆盖别的记录。
    /// 待签名记录是「同一 IPA 导入多个副本、用不同 Bundle ID 分别签名并存」那条刻意
    /// 保留路径的产物，被替换掉就毁掉了多副本能力。
    @Test
    func overwriteUpdateFallsBackToNewRecordWhenTargetIsNotInstalled() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let pendingID = UUID()
        let pending = AppRecord(
            id: pendingID,
            originalBundleIdentifier: "com.example.demo",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 10,
            state: .preflightPassed,
            ipaRelativePath: "Apps/\(pendingID.uuidString)/Original.ipa",
            importedAt: Date(timeIntervalSince1970: 100)
        )
        try await environment.appStore.save(pending)

        let source = try IPAArchiveFixture.make()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let draftAppID = UUID()
        let workflow = makeWorkflow(environment: environment, appID: draftAppID)

        await workflow.prepare(sourceURL: source)
        await workflow.confirm(target: .replaceInstalled(appID: pendingID))

        let imported = try requireCompleted(await workflow.state)
        let records = try await environment.appStore.fetchAll()
        #expect(records.count == 2)
        #expect(imported.id == draftAppID)
        #expect(imported.belongsInInstalledList == false)
        #expect(records.contains { $0.id == pendingID })
    }

    /// 目标记录在确认页停留期间被删掉 ⇒ 同样回落新建，而不是「随便挑一条替换」。
    @Test
    func overwriteUpdateFallsBackWhenTargetRecordIsGone() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let installedID = UUID()
        let installed = AppRecord(
            id: installedID,
            originalBundleIdentifier: "com.example.demo",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 10,
            state: .installed,
            lastInstalledAt: Date(timeIntervalSince1970: 1_700_000_100),
            ipaRelativePath: "Apps/\(installedID.uuidString)/Original.ipa",
            importedAt: Date(timeIntervalSince1970: 100)
        )
        try await environment.appStore.save(installed)

        let source = try IPAArchiveFixture.make()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let draftAppID = UUID()
        let workflow = makeWorkflow(environment: environment, appID: draftAppID)

        await workflow.prepare(sourceURL: source)
        await workflow.confirm(target: .replaceInstalled(appID: UUID()))

        let imported = try requireCompleted(await workflow.state)
        #expect(imported.id == draftAppID)
        #expect(try await environment.appStore.fetchAll().count == 2)
    }

    /// 重试必须沿用用户已确认的「覆盖更新」目标：悄悄变回「新建」会让两条记录
    /// 争同一个签名身份（签名时被 `SEAL-BUNDLE-004` 拦下），用户又回到待签页。
    @Test
    func retryKeepsTheConfirmedOverwriteTarget() async throws {
        let store = ArmedFailOnceAppStore()
        let environment = try makeEnvironment(appStore: store)
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let installedID = UUID()
        let installed = AppRecord(
            id: installedID,
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: "com.example.demo.3432ZHJUF9",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 10,
            state: .installed,
            accountID: UUID(),
            lastInstalledAt: Date(timeIntervalSince1970: 1_700_000_100),
            ipaRelativePath: "Apps/\(installedID.uuidString)/Original.ipa",
            importedAt: Date(timeIntervalSince1970: 100)
        )
        await store.seed(installed)
        await store.armFailure()

        let source = try IPAArchiveFixture.make()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let draftAppID = UUID()
        let workflow = makeWorkflow(environment: environment, appID: draftAppID)

        await workflow.prepare(sourceURL: source)
        await workflow.confirm(target: .replaceInstalled(appID: installedID))
        let failure = try requireFailure(await workflow.state)
        #expect(failure.code == "SEAL-IPA-205")

        await workflow.retry()

        let updated = try requireCompleted(await workflow.state)
        let records = try await environment.appStore.fetchAll()
        #expect(records.count == 1)
        #expect(updated.id == installedID)
        #expect(updated.belongsInInstalledList)
    }

    /// 真机现象「连 Seal 自己也装不了」：记录里的身份（original/mapped/preferred）与
    /// 导入包**都对不上**时，`preferredExistingSealRecordForImportedIPA` 返回 nil ⇒
    /// 旧实现会新建一条 `isSeal == false` 的记录落到待签名页，签名时又被
    /// `SEAL-BUNDLE-004` 拦下。兜底判据必须把「导入的就是**运行中**的 Seal」接住。
    @Test
    func importingTheRunningSealBuildFallsBackToSelfUpdateEvenWhenRecordIdentityDiffers() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let sealID = UUID()
        let installedSeal = AppRecord(
            id: sealID,
            originalBundleIdentifier: "com.mjorb.seal.legacy",
            name: "Seal",
            version: "1.0",
            buildNumber: "1",
            size: 10,
            state: .installed,
            ipaRelativePath: "Apps/\(sealID.uuidString)/Original.ipa",
            isSeal: true,
            isPinned: true,
            importedAt: Date(timeIntervalSince1970: 100)
        )
        try await environment.appStore.save(installedSeal)

        let source = try IPAArchiveFixture.make(
            apps: [
                .init(
                    directoryName: "Seal.app",
                    bundleIdentifier: "com.mjorb.seal",
                    name: "Seal",
                    version: "2.0",
                    buildNumber: "82"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let workflow = makeWorkflow(
            environment: environment,
            appID: UUID(),
            runningSealBundleIdentifier: "com.mjorb.seal"
        )

        await workflow.prepare(sourceURL: source)
        await workflow.confirm()

        let imported = try requireCompleted(await workflow.state)
        #expect(imported.id == sealID)
        #expect(imported.isSeal)
        #expect(imported.version == "2.0")
        #expect(try await environment.appStore.fetchAll().count == 1)
    }
}

private extension ImportWorkflowTests {
    /// 与 `FailOnceAppStore` 的区别：可以先**预置**已安装记录、再武装失败。
    /// 覆盖更新的重试用例需要「记录已在库里 + 第一次保存失败」这个组合。
    actor ArmedFailOnceAppStore: AppStore {
        private var records: [AppRecord] = []
        private var remainingFailures = 0

        func seed(_ record: AppRecord) {
            records.removeAll { $0.id == record.id }
            records.append(record)
        }

        func armFailure() {
            remainingFailures += 1
        }

        func fetchAll() -> [AppRecord] {
            records
        }

        func save(_ record: AppRecord) throws {
            if remainingFailures > 0 {
                remainingFailures -= 1
                throw AppStoreError.invalidConfiguration
            }
            records.removeAll { $0.id == record.id }
            records.append(record)
        }

        func replaceImportedApp(_ record: AppRecord) throws -> [AppRecord] {
            []
        }

        func delete(id: UUID) {
            records.removeAll { $0.id == id }
        }
    }
}
