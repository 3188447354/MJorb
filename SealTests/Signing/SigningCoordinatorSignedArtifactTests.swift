import Foundation
import Testing
import ZIPFoundation
@testable import Seal

struct SigningCoordinatorSignedArtifactTests {
    @Test
    func installsPersistedSignedArtifactWithoutRunningSigningAgain() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let appID = UUID()
        let source = environment.root.appending(path: "AlreadySigned.ipa")
        try Self.makeMinimalValidIPA(
            at: source,
            bundleID: "com.example.demo.seal",
            executableName: "Demo"
        )
        let signedPath = try await environment.fileStore.storeSignedIPA(sourceURL: source, appID: appID)
        let sha = try await environment.fileStore.sha256(relativePath: signedPath)
        let expiration = Date().addingTimeInterval(3 * 86_400)
        let app = AppRecord(
            id: appID,
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: "com.example.demo.seal",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 18,
            state: .signed,
            signedDeviceIdentifier: "DEVICE-1",
            provisioningProfileExpirationDate: expiration,
            ipaRelativePath: "Apps/\(appID.uuidString)/Original.ipa",
            signedIPARelativePath: signedPath,
            signedIPASHA256: sha,
            signedArtifactStatus: .available,
            preferredBundleIdentifier: "com.example.demo.seal",
            importedAt: Date()
        )
        try await environment.appStore.save(app)

        let coordinator = SigningCoordinator(
            appStore: environment.appStore,
            accountRepository: environment.accountRepository,
            keychain: KeychainVault(),
            fileStore: environment.fileStore,
            installChannel: environment.installChannel
        )
        let result = try await coordinator.installSignedArtifact(appID: appID) { _ in }

        #expect(result.state == .installed)
        #expect(result.signedArtifactStatus == .installed)
        #expect(result.mappedBundleIdentifier == "com.example.demo.seal")
        #expect(await environment.installChannel.installCount == 1)
        #expect(await environment.installChannel.verifyCount == 1)
    }

    @Test
    func sealInstallDelegatesOnePreparedTransaction() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let appID = UUID()
        let accountID = UUID()
        let source = environment.root.appending(path: "SealSigned.ipa")
        try Self.makeMinimalValidIPA(
            at: source,
            bundleID: "com.mjorb.seal",
            executableName: "Seal",
            extraInfoPlistEntries: [
                "UIFileSharingEnabled": true,
                "LSSupportsOpeningDocumentsInPlace": true
            ]
        )
        let signedPath = try await environment.fileStore.storeSignedIPA(sourceURL: source, appID: appID)
        let sha = try await environment.fileStore.sha256(relativePath: signedPath)
        let app = AppRecord(
            id: appID,
            originalBundleIdentifier: "com.mjorb.seal",
            mappedBundleIdentifier: "com.mjorb.seal",
            name: "Seal",
            version: "1.0",
            buildNumber: "1",
            size: 18,
            state: .installed,
            expiryDate: Date().addingTimeInterval(3_600),
            accountID: accountID,
            signedDeviceIdentifier: "DEVICE-1",
            provisioningProfileExpirationDate: Date().addingTimeInterval(6 * 86_400),
            lastInstalledAt: Date(),
            ipaRelativePath: "Apps/\(appID.uuidString)/Original.ipa",
            signedIPARelativePath: signedPath,
            signedIPASHA256: sha,
            signedArtifactStatus: .available,
            isSeal: true,
            importedAt: Date()
        )
        try await environment.appStore.save(app)
        let replacement = RecordingSelfReplacement()
        let coordinator = SigningCoordinator(
            appStore: environment.appStore,
            accountRepository: environment.accountRepository,
            keychain: KeychainVault(),
            fileStore: environment.fileStore,
            installChannel: environment.installChannel,
            selfReplacement: replacement
        )

        let result = try await coordinator.installSignedArtifact(appID: appID) { _ in }

        // Seal 安装必须委托给自替换事务：恰好 prepare 一次、submit 一次，
        // 当前进程不再直接触碰安装通道，也不在本进程内推进安装成功。
        #expect(await replacement.prepareCount == 1)
        #expect(await replacement.submitCount == 1)
        #expect(await replacement.preparedAppID == appID)
        #expect(await replacement.preparedAccountID == accountID)
        #expect(await replacement.preparedSignedPath == signedPath)
        #expect(await environment.installChannel.installCount == 0)
        #expect(await environment.installChannel.verifyCount == 0)
        #expect(result.signedArtifactStatus == .awaitingVerification)
        let stored = try #require(try await environment.appStore.fetchAll().first { $0.id == appID })
        #expect(stored.signedArtifactStatus == .awaitingVerification)
        #expect(stored.state == .installed)
    }

    @Test
    func sealInstallWithoutReplacementCoordinatorIsRejectedBeforeInstall() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let appID = UUID()
        let source = environment.root.appending(path: "SealSigned.ipa")
        try Self.makeMinimalValidIPA(
            at: source,
            bundleID: "com.mjorb.seal",
            executableName: "Seal",
            extraInfoPlistEntries: [
                "UIFileSharingEnabled": true,
                "LSSupportsOpeningDocumentsInPlace": true
            ]
        )
        let signedPath = try await environment.fileStore.storeSignedIPA(sourceURL: source, appID: appID)
        let sha = try await environment.fileStore.sha256(relativePath: signedPath)
        let app = AppRecord(
            id: appID,
            originalBundleIdentifier: "com.mjorb.seal",
            mappedBundleIdentifier: "com.mjorb.seal",
            name: "Seal",
            version: "1.0",
            buildNumber: "1",
            size: 18,
            state: .installed,
            accountID: UUID(),
            signedDeviceIdentifier: "DEVICE-1",
            provisioningProfileExpirationDate: Date().addingTimeInterval(6 * 86_400),
            ipaRelativePath: "Apps/\(appID.uuidString)/Original.ipa",
            signedIPARelativePath: signedPath,
            signedIPASHA256: sha,
            signedArtifactStatus: .available,
            isSeal: true,
            importedAt: Date()
        )
        try await environment.appStore.save(app)
        let coordinator = SigningCoordinator(
            appStore: environment.appStore,
            accountRepository: environment.accountRepository,
            keychain: KeychainVault(),
            fileStore: environment.fileStore,
            installChannel: environment.installChannel
        )

        do {
            _ = try await coordinator.installSignedArtifact(appID: appID) { _ in }
            Issue.record("Seal install without a replacement coordinator must not reach the install channel")
        } catch let failure as ImportFailure {
            #expect(failure.code == "SEAL-INSTALL-737")
        }
        #expect(await environment.installChannel.installCount == 0)
    }

    @Test
    func missingSignedFileIsKeptAsRecordAndMarkedMissing() async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let appID = UUID()
        let app = AppRecord(
            id: appID,
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: "com.example.demo.seal",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 18,
            state: .signed,
            signedDeviceIdentifier: "DEVICE-1",
            provisioningProfileExpirationDate: Date().addingTimeInterval(86_400),
            ipaRelativePath: "Apps/\(appID.uuidString)/Original.ipa",
            signedIPARelativePath: "Apps/\(appID.uuidString)/Signed.ipa",
            signedIPASHA256: String(repeating: "a", count: 64),
            signedArtifactStatus: .available,
            preferredBundleIdentifier: "com.example.demo.seal",
            importedAt: Date()
        )
        try await environment.appStore.save(app)
        let coordinator = SigningCoordinator(
            appStore: environment.appStore,
            accountRepository: environment.accountRepository,
            keychain: KeychainVault(),
            fileStore: environment.fileStore,
            installChannel: environment.installChannel
        )

        do {
            _ = try await coordinator.installSignedArtifact(appID: appID) { _ in }
            Issue.record("Expected missing signed artifact failure")
        } catch let failure as ImportFailure {
            #expect(failure.code == "SEAL-INSTALL-711")
        }
        let records = try await environment.appStore.fetchAll()
        let stored = try #require(records.first { $0.id == appID })
        #expect(stored.state == .signed)
        #expect(stored.signedArtifactStatus == .missing)
    }

    @Test(arguments: ["SEAL-INSTALL-702l", "SEAL-INSTALL-702s", "SEAL-INSTALL-702"])
    func failedReplacementPreservesInstalledExpiryAndOriginalError(code: String) async throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let appID = UUID()
        let source = environment.root.appending(path: "Replacement.ipa")
        try Self.makeMinimalValidIPA(at: source, bundleID: "com.example.demo.seal", executableName: "Demo")
        let path = try await environment.fileStore.storeSignedIPA(sourceURL: source, appID: appID)
        let hash = try await environment.fileStore.sha256(relativePath: path)
        let oldExpiry = Date().addingTimeInterval(3600)
        let app = AppRecord(
            id: appID, originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: "com.example.demo.seal", name: "Demo", version: "1", buildNumber: "1",
            size: 1, state: .installed, expiryDate: oldExpiry,
            signedDeviceIdentifier: "DEVICE-1",
            provisioningProfileExpirationDate: Date().addingTimeInterval(6 * 86_400),
            lastInstalledAt: Date(), ipaRelativePath: "Apps/\(appID)/Original.ipa",
            signedIPARelativePath: path, signedIPASHA256: hash, signedArtifactStatus: .available,
            importedAt: Date()
        )
        try await environment.appStore.save(app)
        await environment.installChannel.rejectInstall(code: code)
        let coordinator = SigningCoordinator(
            appStore: environment.appStore, accountRepository: environment.accountRepository,
            keychain: KeychainVault(), fileStore: environment.fileStore,
            installChannel: environment.installChannel
        )
        do {
            _ = try await coordinator.installSignedArtifact(appID: appID) { _ in }
            Issue.record("A rejected replacement must never become successful")
        } catch let failure as ImportFailure {
            #expect(failure.code == code)
        }
        let stored = try #require(try await environment.appStore.fetchAll().first { $0.id == appID })
        #expect(stored.expiryDate == oldExpiry)
        #expect(stored.state == .installed)
        #expect(stored.signedArtifactStatus == .installFailed)
        #expect(stored.lastInstallFailureCode == code)
        #expect(await environment.installChannel.verifyCount == 0)
    }

    @Test
    func rejectsMissingExecutableDeclaration() throws {
        try assertInvalidExecutable(nil)
    }

    @Test(arguments: ["", " ", ".", "..", "../outside", "dir/Demo", "dir\\Demo"])
    func rejectsUnsafeExecutableDeclaration(name: String) throws {
        try assertInvalidExecutable(name, entryName: name.isEmpty ? "Demo" : name)
    }

    @Test
    func rejectsEmptyExecutable() throws {
        try assertInvalidExecutable("Demo", data: Data())
    }

    private func assertInvalidExecutable(_ name: String?, data: Data = Data("fixture".utf8), entryName: String = "Demo") throws {
        let environment = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: environment.root) }
        let source = environment.root.appending(path: "Invalid.ipa")
        try Self.makeMinimalValidIPA(at: source, bundleID: "com.example.demo", executableName: name, executableData: data, executableEntryName: entryName)
        let validation = SignedArtifactValidator.validate(
            ipaData: try Data(contentsOf: source), expectedBundleID: "com.example.demo"
        )
        #expect(validation.isValid == false)
        #expect(validation.failureCode == "SEAL-INSTALL-730")
    }

    private func makeEnvironment() throws -> Environment {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "SealSignedArtifactTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let cache = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let appStore = try CoreDataAppStore(inMemory: true)
        let accountRepository = ProtectedAccountRepository(
            fileURL: root.appending(path: "Accounts.json"),
            fileProtector: MarkerFileProtector()
        )
        return Environment(
            root: root,
            fileStore: AppFileStore(documentsDirectory: documents, cacheDirectory: cache),
            appStore: appStore,
            accountRepository: accountRepository,
            installChannel: SignedArtifactInstallChannel()
        )
    }
}

private extension SigningCoordinatorSignedArtifactTests {
    struct Environment {
        let root: URL
        let fileStore: AppFileStore
        let appStore: CoreDataAppStore
        let accountRepository: ProtectedAccountRepository
        let installChannel: SignedArtifactInstallChannel
    }
}

private actor RecordingSelfReplacement: SelfReplacing {
    private(set) var prepareCount = 0
    private(set) var submitCount = 0
    private(set) var preparedAppID: UUID?
    private(set) var preparedAccountID: UUID?
    private(set) var preparedSignedPath: String?

    func prepare(
        app: AppRecord,
        accountID: UUID,
        signedIPARelativePath: String
    ) async throws -> SelfReplacementTransaction {
        prepareCount += 1
        preparedAppID = app.id
        preparedAccountID = accountID
        preparedSignedPath = signedIPARelativePath
        let id = UUID()
        return .make(
            id: id,
            accountID: accountID,
            preparedProcessID: UUID(),
            installedBefore: .unknown(bundleIdentifier: app.mappedBundleIdentifier ?? app.originalBundleIdentifier),
            candidate: .legacy(
                transactionID: id,
                bundleIdentifier: app.mappedBundleIdentifier ?? app.originalBundleIdentifier,
                teamIdentifier: "TEAM",
                profileUUID: "profile",
                certificateSerialNumber: "ABC"
            ),
            signedIPARelativePath: signedIPARelativePath
        )
    }

    func submitPrepared(
        transactionID: UUID,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        submitCount += 1
    }
}

private actor SignedArtifactInstallChannel: InstallChannel {
    private(set) var installCount = 0
    private(set) var verifyCount = 0
    private(set) var pushCount = 0
    private(set) var pushedInstallCount = 0
    private var installFailure: ImportFailure?

    func rejectInstall(code: String) {
        installFailure = ImportFailure(title: "安装失败", reason: "fixture rejection", recovery: "人工处理", code: code)
    }

    func start() async throws -> String { "DEVICE-1" }
    func diagnose() async -> InstallChannelDiagnostics { .empty }
    func isReady() async -> Bool { true }
    func pushIpa(ipaData: Data, bundleID: String) async throws {
        pushCount += 1
    }
    func installPushedIpa(bundleID: String, isSelfReplacement: Bool) async throws {
        pushedInstallCount += 1
    }
    func install(ipaData: Data, bundleID: String, isSelfReplacement: Bool) async throws {
        installCount += 1
        if let installFailure { throw installFailure }
    }
    func verifyInstalled(bundleID: String) async throws {
        verifyCount += 1
    }
}

private extension SigningCoordinatorSignedArtifactTests {
    /// 创建一个结构完整的最小有效 IPA（通过 SignedArtifactValidator 的所有检查）。
    static func makeMinimalValidIPA(
        at url: URL,
        bundleID: String,
        executableName: String?,
        executableData: Data = Data("fixture-executable".utf8),
        executableEntryName: String = "Demo",
        extraInfoPlistEntries: [String: Any] = [:]
    ) throws {
        let archive = try Archive(url: url, accessMode: .create)

        func addData(_ data: Data, _ path: String) throws {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size in
                    let start = Int(position)
                    return data.subdata(in: start..<(start + size))
                }
            )
        }

        // Info.plist
        var infoPlist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": "Demo"
        ]
        if let executableName { infoPlist["CFBundleExecutable"] = executableName }
        extraInfoPlistEntries.forEach { infoPlist[$0.key] = $0.value }
        let infoPlistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist,
            format: .xml,
            options: 0
        )
        try addData(infoPlistData, "Payload/Demo.app/Info.plist")

        // embedded.mobileprovision（模拟，内容不校验）
        try addData(Data("mock-mobileprovision".utf8), "Payload/Demo.app/embedded.mobileprovision")

        // Not a cryptographic signature fixture; exercise structural validation only.
        try addData(executableData, "Payload/Demo.app/\(executableEntryName)")
    }
}
