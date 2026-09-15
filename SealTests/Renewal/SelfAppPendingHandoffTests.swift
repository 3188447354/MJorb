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
