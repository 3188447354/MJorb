import Foundation
import Testing
@testable import Seal

struct SelfSigningHandoffTests {
    @Test
    func confirmsOnlyOnNextProcessWithMatchingRunningProfile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "handoff.json")
        let first = SelfSigningHandoffStore(fileURL: fileURL, fileProtector: MarkerFileProtector())
        try await prepare(first)
        let pending = try #require(await first.loadPending())
        #expect(try await first.confirm(metadata: metadata(), pendingID: pending.id, materialStatus: .available) == .awaitingRestart)

        let sameProcess = SelfSigningHandoffStore(fileURL: fileURL, fileProtector: MarkerFileProtector())
        #expect(try await sameProcess.confirm(metadata: metadata(), pendingID: pending.id, materialStatus: .available) == .awaitingRestart)
        let restarted = SelfSigningHandoffStore(fileURL: fileURL, processIdentifier: UUID(), fileProtector: MarkerFileProtector())
        #expect(try await restarted.loadPending() == pending)
        #expect(try await restarted.confirm(metadata: metadata(), pendingID: pending.id, materialStatus: .available) == .confirmed)
        #expect(try await restarted.loadPending() == nil)
        let third = SelfSigningHandoffStore(fileURL: fileURL, fileProtector: MarkerFileProtector())
        #expect(try await third.loadPending() == nil)
    }

    @Test
    func oldBundleAndUnavailableMaterialKeepPendingAcrossRestart() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "handoff.json")
        let first = SelfSigningHandoffStore(fileURL: fileURL, fileProtector: MarkerFileProtector())
        try await prepare(first)
        let restarted = SelfSigningHandoffStore(fileURL: fileURL, processIdentifier: UUID(), fileProtector: MarkerFileProtector())
        let pending = try #require(await restarted.loadPending())
        var oldMetadata = metadata()
        oldMetadata.provisioningProfileUUID = "old-profile"
        #expect(try await restarted.confirm(metadata: oldMetadata, pendingID: pending.id, materialStatus: .available) == .profileMismatch)
        #expect(try await restarted.confirm(metadata: metadata(), pendingID: pending.id, materialStatus: .missingPrivateKey) == .missingPrivateKey)
        #expect(try await restarted.confirm(metadata: metadata(), pendingID: pending.id, materialStatus: .unusableCertificate) == .unusableCertificate)
        #expect(try await restarted.loadPending() == pending)
    }

    @Test
    func wrongBundleTeamOrCertificateCannotConfirm() {
        let pending = SelfSigningHandoff(accountID: UUID(), bundleIdentifier: "com.mjorb.seal", teamIdentifier: "TEAM", profileUUID: "new-profile", certificateSerialNumber: "0ABC", preparedInProcess: UUID())
        #expect(SelfSigningHandoffPolicy.evaluate(pending: pending, metadata: metadata(bundle: "com.other.app"), materialStatus: .available) == .bundleMismatch)
        #expect(SelfSigningHandoffPolicy.evaluate(pending: pending, metadata: metadata(team: "OTHER"), materialStatus: .available) == .teamMismatch)
        var wrongCertificate = metadata()
        wrongCertificate.certificateSerialNumbers = ["DEF"]
        #expect(SelfSigningHandoffPolicy.evaluate(pending: pending, metadata: wrongCertificate, materialStatus: .available) == .certificateMismatch)
        #expect(SelfSigningHandoffPolicy.evaluate(pending: pending, metadata: metadata(), materialStatus: .available) == .confirmed)
    }

    @Test
    func staleConfirmationCannotOverwriteNewAttempt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SelfSigningHandoffStore(fileURL: directory.appending(path: "handoff.json"), fileProtector: MarkerFileProtector())
        try await prepare(store)
        let old = try #require(await store.loadPending())
        try await prepare(store)
        #expect(try await store.confirm(metadata: metadata(), pendingID: old.id, materialStatus: .available) == .superseded)
        #expect(try await store.loadPending()?.id != old.id)
    }

    @Test
    func automaticRecoveryCanBeClaimedOnlyOncePerSignedArtifact() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SelfSigningHandoffStore(
            fileURL: directory.appending(path: "handoff.json"),
            fileProtector: MarkerFileProtector()
        )
        let accountID = UUID()
        try await store.prepare(
            accountID: accountID,
            bundleIdentifier: "com.mjorb.seal",
            teamIdentifier: "TEAM",
            profileUUID: "profile-one",
            certificateSerialNumber: "0ABC"
        )
        let first = try #require(await store.loadPending())
        #expect(try await store.claimAutomaticRecovery(pendingID: first.id))
        #expect(try await store.claimAutomaticRecovery(pendingID: first.id) == false)

        // 自动恢复内部会再次 prepare 同一成品；已领取状态必须保留。
        try await store.prepare(
            accountID: accountID,
            bundleIdentifier: "com.mjorb.seal",
            teamIdentifier: "TEAM",
            profileUUID: "profile-one",
            certificateSerialNumber: "ABC"
        )
        let sameArtifact = try #require(await store.loadPending())
        #expect(sameArtifact.automaticRecoveryAttemptedAt != nil)
        #expect(try await store.claimAutomaticRecovery(pendingID: sameArtifact.id) == false)

        // 用户重新签名产生新 profile 后，新的成品重新拥有一次恢复资格。
        try await store.prepare(
            accountID: accountID,
            bundleIdentifier: "com.mjorb.seal",
            teamIdentifier: "TEAM",
            profileUUID: "profile-two",
            certificateSerialNumber: "ABC"
        )
        let newArtifact = try #require(await store.loadPending())
        #expect(newArtifact.automaticRecoveryAttemptedAt == nil)
        #expect(try await store.claimAutomaticRecovery(pendingID: newArtifact.id))
    }

    @Test
    func persistenceFailureIsReportedBeforeInstallationCanStart() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appending(path: "file-not-directory")
        try Data().write(to: blocker)
        let store = SelfSigningHandoffStore(fileURL: blocker.appending(path: "handoff.json"), fileProtector: MarkerFileProtector())
        await #expect(throws: (any Error).self) { try await prepare(store) }
    }

    private func prepare(_ store: SelfSigningHandoffStore) async throws {
        try await store.prepare(accountID: UUID(), bundleIdentifier: "com.mjorb.seal", teamIdentifier: "TEAM", profileUUID: "new-profile", certificateSerialNumber: "0ABC")
    }

    private func metadata(bundle: String = "com.mjorb.seal", team: String = "TEAM") -> SelfAppMetadata {
        SelfAppMetadata(bundleURL: URL(fileURLWithPath: "/Seal.app"), bundleIdentifier: bundle, originalBundleIdentifier: nil, name: "Seal", version: "1.1.12", buildNumber: "1", iconData: nil, expirationDate: .distantFuture, signingTeamIdentifier: team, signingApplicationIdentifier: nil, provisioningProfileUUID: "new-profile", certificateSerialNumbers: ["ABC"])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "SealHandoffTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
