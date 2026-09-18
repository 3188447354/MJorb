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

    /// 迁移出来的 legacy 事务**必须**是终态。
    ///
    /// 它没有候选版本、也没有安装前身份快照，`SelfReplacementPolicy.reconcile` 里
    /// `candidate.matches(running)` 与 `running == installedBefore` 两条判据恒假 ⇒
    /// 只能落到 `requireRecovery`，而后者只改 phase 不设 `settledAt`：
    /// 每次启动都判「需电脑覆盖恢复」，`create` 又因存在 pending 抛 `alreadySubmitted`
    /// ——Seal 从此永久无法自续签。这条测试钉的就是「不再占住槽位」。
    @Test
    func legacyHandoffMigrationReleasesThePendingSlot() async throws {
        let fixture = try TransactionFixture.withLegacyHandoff()

        let pending = await fixture.store.loadPending()
        #expect(pending == nil, "legacy 迁移结果不得留在 pending，否则自续签被永久锁死")

        let audit = try await fixture.store.loadAny()
        let closed = try #require(audit)
        #expect(closed.phase == .recoveryRequired)
        #expect(closed.settledAt != nil)
        #expect(closed.failureCode?.contains("SEAL-SELF-LEGACY-UNVERIFIABLE") == true)

        // 槽位释放后，新的自替换事务必须能正常建立（这才是用户可感知的修复）。
        let created = try await fixture.store.create(.fixture)
        #expect(created.phase == .prepared)
    }

    @Test
    func legacyMigrationIsStableAcrossRepeatedLoads() async throws {
        let fixture = try TransactionFixture.withLegacyHandoff()
        let first = try #require(await fixture.store.loadAny())
        _ = await fixture.store.loadPending()
        let second = try #require(await fixture.store.loadAny())
        #expect(first.id == second.id)
        #expect(first.settledAt == second.settledAt)
        #expect(second.phase == .recoveryRequired)
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
