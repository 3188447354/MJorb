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
    func importingSealIPACreatesPendingReplacementWithoutMutatingInstalledSeal() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let sealID = UUID()
        let accountID = UUID()
        let previousOriginalPath = "Apps/\(sealID.uuidString)/Original.ipa"
        let installedSeal = AppRecord(
            id: sealID,
            originalBundleIdentifier: "com.mjorb.seal",
            mappedBundleIdentifier: "com.mjorb.seal.TEAM000001",
            name: "Seal",
            version: "1.0",
            buildNumber: "1",
            size: 10,
            state: .installed,
            expiryDate: Date(timeIntervalSince1970: 1_800_000_000),
            accountID: accountID,
            signingTeamID: "TEAM000001",
            certificateSerialNumber: "SERIAL",
            signedDeviceIdentifier: "DEVICE",
            provisioningProfileExpirationDate: Date(timeIntervalSince1970: 1_800_000_000),
            lastSignedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastInstalledAt: Date(timeIntervalSince1970: 1_700_000_100),
            ipaRelativePath: previousOriginalPath,
            signedIPARelativePath: "Apps/\(sealID.uuidString)/Signed.ipa",
            signedIPASHA256: "old-sha",
            signedArtifactStatus: .installed,
            preferredBundleIdentifier: "com.mjorb.seal.TEAM000001",
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
        #expect(records.count == 2)
        #expect(imported.id != sealID)
        #expect(imported.isSeal)
        #expect(imported.state == .imported)
        #expect(imported.replacesInstalledAppID == sealID)
        #expect(imported.belongsInInstalledList == false)
        #expect(imported.belongsInUnsignedList)
        #expect(imported.version == "2.0")
        #expect(imported.buildNumber == "82")
        #expect(imported.accountID == accountID)
        #expect(imported.signingTeamID == "TEAM000001")
        #expect(imported.certificateSerialNumber == nil)
        #expect(imported.signedDeviceIdentifier == nil)
        #expect(imported.lastInstalledAt == nil)
        #expect(imported.signedIPARelativePath == nil)
        #expect(imported.signedIPASHA256 == nil)
        #expect(imported.signedArtifactStatus == nil)
        #expect(imported.ipaRelativePath == "Apps/\(imported.id.uuidString)/Original.ipa")
        #expect(FileManager.default.fileExists(atPath: oldIPA.path))
        #expect(try Data(contentsOf: oldIPA) == Data("old-seal".utf8))
    }

    /// 同版本导入 Seal 自身 IPA 也要能覆盖更新（2026-10-02 用户需求）：
    /// 导入时必须把源包指纹写进记录 —— 版本号相同时续签准入只能靠它
    /// 认出「有待安装的更新源」（`ProfileOnlyRenewalPolicy.hasPendingUpdateSource`）。
    @Test
    func importingSealIPAWithSameVersionRecordsSourceFingerprint() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let sealID = UUID()
        let previousOriginalPath = "Apps/\(sealID.uuidString)/Original.ipa"
        let installedSeal = AppRecord(
            id: sealID,
            originalBundleIdentifier: "com.mjorb.seal",
            mappedBundleIdentifier: "com.mjorb.seal.TEAM000001",
            name: "Seal",
            version: "1.0",
            buildNumber: "1",
            size: 10,
            state: .installed,
            ipaRelativePath: previousOriginalPath,
            installedFingerprint: "previous-installed-fingerprint",
            preferredBundleIdentifier: "com.mjorb.seal.TEAM000001",
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

        // 导入包与运行中版本**相同**（1.0），只是内容不同。
        let source = try IPAArchiveFixture.make(
            apps: [
                .init(
                    directoryName: "Seal.app",
                    bundleIdentifier: "com.mjorb.seal",
                    name: "Seal",
                    version: "1.0",
                    buildNumber: "2"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let workflow = makeWorkflow(environment: environment, appID: UUID())

        await workflow.prepare(sourceURL: source)
        await workflow.confirm()

        let imported = try requireCompleted(await workflow.state)
        #expect(imported.id != sealID)
        #expect(imported.version == "1.0")
        #expect(imported.state == .imported)
        #expect(imported.replacesInstalledAppID == sealID)
        #expect(try await environment.appStore.fetchAll().count == 2)
        // 指纹 = 导入源包的 SHA256（流式算的，不整包进内存）。
        let expectedFingerprint = try await environment.fileStore.sha256(
            relativePath: imported.ipaRelativePath
        )
        #expect(imported.pendingUpdateSourceFingerprint == expectedFingerprint)
        // 准入判据认得出这是待安装更新：版本一致 + 有指纹 ⇒ 回落完整重签。
        #expect(
            ProfileOnlyRenewalPolicy.hasPendingUpdateSource(
                recordedVersion: imported.version,
                runningVersion: "1.0",
                pendingUpdateSourceFingerprint: imported.pendingUpdateSourceFingerprint
            )
        )
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
    /// 覆盖更新导入的是独立待签名记录：旧的已安装记录必须保留，直到安装并通过
    /// 设备核验；新记录继承安装身份并精确指向旧记录，供安装成功时原子切换。
    @Test
    func overwriteUpdateCreatesPendingReplacementWithoutMutatingInstalledRecord() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let installedID = UUID()
        let accountID = UUID()
        let originalPath = "Apps/\(installedID.uuidString)/Original.ipa"
        let installed = AppRecord(
            id: installedID,
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: "com.example.demo.TEAM000001",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 10,
            state: .installed,
            expiryDate: Date(timeIntervalSince1970: 1_800_000_000),
            accountID: accountID,
            signingTeamID: "TEAM000001",
            certificateSerialNumber: "SERIAL",
            signedDeviceIdentifier: "DEVICE",
            provisioningProfileExpirationDate: Date(timeIntervalSince1970: 1_800_000_000),
            lastSignedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastInstalledAt: Date(timeIntervalSince1970: 1_700_000_100),
            ipaRelativePath: originalPath,
            signedIPARelativePath: "Apps/\(installedID.uuidString)/Signed.ipa",
            signedIPASHA256: "old-sha",
            signedArtifactStatus: .installed,
            preferredBundleIdentifier: "com.example.demo.TEAM000001",
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
        #expect(records.count == 2)
        #expect(updated.id != installedID)
        #expect(updated.version == "1.2.3")
        #expect(updated.state == .imported)
        #expect(updated.belongsInInstalledList == false)
        #expect(updated.belongsInUnsignedList)
        #expect(updated.replacesInstalledAppID == installedID)
        // 签名身份必须保留：换了身份 installd 就不能覆盖设备上的同一 App。
        #expect(updated.mappedBundleIdentifier == "com.example.demo.TEAM000001")
        #expect(updated.accountID == accountID)
        #expect(updated.signingTeamID == "TEAM000001")
        #expect(updated.lastInstalledAt == nil)
        // 新包尚未签名，不能携带旧版本签名产物。
        #expect(updated.signedIPARelativePath == nil)
        #expect(updated.signedIPASHA256 == nil)
        #expect(updated.signedArtifactStatus == nil)
        // 两条记录各自使用与 UUID 相符的目录，旧版资料在新包验证前不可被覆盖。
        #expect(updated.ipaRelativePath == "Apps/\(updated.id.uuidString)/Original.ipa")
        #expect(FileManager.default.fileExists(atPath: oldIPA.path))
        #expect(try Data(contentsOf: oldIPA) == Data("old".utf8))
        // 草稿自己的 appID 不该在磁盘上留下目录；更新记录使用自己的新 UUID。
        #expect(FileManager.default.fileExists(
            atPath: environment.documents.appending(path: "Apps/\(draftAppID.uuidString)").path
        ) == false)
    }

    /// 已明确选择覆盖的目标若不是已安装记录，必须中止并提示重新选择；
    /// 静默回落新建会制造用户没有要求的同身份副本。
    @Test
    func overwriteUpdateFailsWhenTargetIsNotInstalled() async throws {
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

        let failure = try requireFailure(await workflow.state)
        let records = try await environment.appStore.fetchAll()
        #expect(failure.code == "SEAL-IPA-217")
        #expect(records.count == 1)
        #expect(records.contains { $0.id == pendingID })
    }

    /// 目标记录在确认页停留期间被删掉 ⇒ 提示重新确认，不能改成新建或随便替换。
    @Test
    func overwriteUpdateFailsWhenTargetRecordIsGone() async throws {
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

        let failure = try requireFailure(await workflow.state)
        #expect(failure.code == "SEAL-IPA-217")
        #expect(try await environment.appStore.fetchAll().count == 1)
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
            mappedBundleIdentifier: "com.example.demo.TEAM000001",
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
        #expect(records.count == 2)
        #expect(updated.id != installedID)
        #expect(updated.replacesInstalledAppID == installedID)
        #expect(updated.belongsInInstalledList == false)
        #expect(records.contains(where: { $0.id == installedID }))
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
        #expect(imported.id != sealID)
        #expect(imported.isSeal)
        #expect(imported.version == "2.0")
        #expect(imported.state == .imported)
        #expect(imported.replacesInstalledAppID == sealID)
        #expect(try await environment.appStore.fetchAll().count == 2)
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

        func commitInstalledReplacement(_ record: AppRecord, replacing replacedID: UUID) throws {
            if remainingFailures > 0 {
                remainingFailures -= 1
                throw AppStoreError.invalidConfiguration
            }
            records.removeAll { $0.id == replacedID || $0.id == record.id }
            records.append(record)
        }

        func delete(id: UUID) {
            records.removeAll { $0.id == id }
        }
    }
}
