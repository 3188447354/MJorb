import Foundation
import Testing
@testable import Seal

struct SelfReplacementTransactionTests {
    @Test
    func submissionCanBeClaimedOnlyOnceEvenAfterRestart() async throws {
        let fileURL = TransactionFixture.temporaryFileURL()
        let store = SelfReplacementTransactionStore(fileURL: fileURL)
        let transaction = try await store.create(.fixture)
        let first = try await store.claimSubmission(transactionID: transaction.id)
        #expect(first.claimedAt <= Date())

        let restarted = SelfReplacementTransactionStore(fileURL: fileURL)
        await #expect(throws: SelfReplacementStoreError.alreadySubmitted) {
            try await restarted.claimSubmission(transactionID: transaction.id)
        }
    }

    @Test
    func legacyHandoffMigratesToAwaitingConfirmation() async throws {
        let fixture = try TransactionFixture.withLegacyHandoff()
        let transaction = try #require(await fixture.store.loadPending())
        #expect(transaction.phase == .awaitingReplacementConfirmation)
        #expect(transaction.submission != nil)
    }
}

private enum TransactionFixture {
    static func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "SealTransactionTests-\(UUID().uuidString)")
            .appending(path: "SelfSigningHandoff.json")
    }

    static func withLegacyHandoff() throws -> (store: SelfReplacementTransactionStore, fileURL: URL) {
        let fileURL = temporaryFileURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacy = LegacySelfSigningHandoff(
            accountID: UUID(),
            bundleIdentifier: "com.example.seal",
            teamIdentifier: "TEAM",
            profileUUID: "PROFILE-UUID",
            certificateSerialNumber: "ABC123",
            preparedInProcess: UUID()
        )
        try JSONEncoder().encode(legacy).write(to: fileURL)
        return (SelfReplacementTransactionStore(fileURL: fileURL), fileURL)
    }
}

private extension SelfReplacementTransaction {
    static var fixture: SelfReplacementTransaction {
        SelfReplacementTransaction.make(
            id: UUID(),
            accountID: UUID(),
            preparedProcessID: UUID(),
            installedBefore: .unknown(bundleIdentifier: "com.example.seal"),
            candidate: .legacy(
                transactionID: UUID(),
                bundleIdentifier: "com.example.seal",
                teamIdentifier: "TEAM",
                profileUUID: "PROFILE-UUID",
                certificateSerialNumber: "ABC123"
            ),
            signedIPARelativePath: "Apps/Seal/Signed.ipa"
        )
    }
}

private struct LegacySelfSigningHandoff: Codable {
    var id = UUID()
    let accountID: UUID
    let bundleIdentifier: String
    let teamIdentifier: String
    let profileUUID: String
    let certificateSerialNumber: String
    let preparedInProcess: UUID
    var automaticRecoveryAttemptedAt: Date? = nil
    var confirmedAt: Date? = nil
}
