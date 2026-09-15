import Foundation

enum SelfReplacementStoreError: Error, Equatable, Sendable {
    case alreadySubmitted
    case pendingNotFound
    case writeFailed
}

actor SelfReplacementTransactionStore {
    private let fileURL: URL
    private let fileProtector: any FileProtecting

    init(
        fileURL: URL,
        fileProtector: any FileProtecting = CompleteFileProtector()
    ) {
        self.fileURL = fileURL
        self.fileProtector = fileProtector
    }

    func create(_ transaction: SelfReplacementTransaction) throws -> SelfReplacementTransaction {
        guard try loadPending() == nil else {
            throw SelfReplacementStoreError.alreadySubmitted
        }
        try write(transaction)
        return transaction
    }

    /// 读取事务（含已关闭），供结算审计断言使用。
    func loadAny() throws -> SelfReplacementTransaction? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        // 先尝试新 schema；失败后尝试旧 SelfSigningHandoff 迁移。
        if let transaction = try? JSONDecoder().decode(SelfReplacementTransaction.self, from: data) {
            return transaction
        }
        if let legacy = try? JSONDecoder().decode(LegacySelfSigningHandoff.self, from: data) {
            let migrated = SelfReplacementTransaction(
                schemaVersion: 1,
                id: legacy.id,
                createdAt: legacy.automaticRecoveryAttemptedAt ?? .distantPast,
                updatedAt: Date(),
                accountID: legacy.accountID,
                preparedProcessID: legacy.preparedInProcess,
                installedBefore: .unknown(bundleIdentifier: legacy.bundleIdentifier),
                candidate: .legacy(
                    transactionID: legacy.id,
                    bundleIdentifier: legacy.bundleIdentifier,
                    teamIdentifier: legacy.teamIdentifier,
                    profileUUID: legacy.profileUUID,
                    certificateSerialNumber: legacy.certificateSerialNumber
                ),
                signedIPARelativePath: "",
                phase: .awaitingReplacementConfirmation,
                submission: .init(id: legacy.id, claimedAt: .distantPast),
                settledAt: nil,
                failureCode: nil,
                cleanupSummary: nil
            )
            try write(migrated)
            return migrated
        }
        return nil
    }

    func loadPending() throws -> SelfReplacementTransaction? {
        guard let transaction = try loadAny(),
              transaction.settledAt == nil,
              transaction.phase != .confirmed else {
            return nil
        }
        return transaction
    }

    func requirePending(id: UUID) throws -> SelfReplacementTransaction {
        guard let transaction = try loadPending(), transaction.id == id else {
            throw SelfReplacementStoreError.pendingNotFound
        }
        return transaction
    }

    func claimSubmission(transactionID: UUID) throws -> SelfReplacementTransaction.Submission {
        var transaction = try requirePending(id: transactionID)
        guard transaction.submission == nil else {
            throw SelfReplacementStoreError.alreadySubmitted
        }
        transaction.phase = .submitting
        let submission = SelfReplacementTransaction.Submission(
            id: UUID(),
            claimedAt: Date()
        )
        transaction.submission = submission
        transaction.updatedAt = Date()
        try write(transaction)
        return submission
    }

    func recordTransportReturn(transactionID: UUID, result: String) throws {
        var transaction = try requirePending(id: transactionID)
        transaction.submission?.returnedAt = Date()
        transaction.submission?.transportResult = result
        transaction.phase = .awaitingReplacementConfirmation
        transaction.updatedAt = Date()
        try write(transaction)
    }

    func updatePhase(
        transactionID: UUID,
        phase: SelfReplacementTransaction.Phase,
        failureCode: String?
    ) throws {
        var transaction = try requirePending(id: transactionID)
        transaction.phase = phase
        transaction.failureCode = failureCode
        transaction.updatedAt = Date()
        try write(transaction)
    }

    /// 终态关闭事务（确认落盘 / 仍在运行旧身份）。关闭后不再参与启动对账，
    /// 但记录保留在磁盘上作为审计证据，直到下一笔事务覆盖。
    func close(
        transactionID: UUID,
        phase: SelfReplacementTransaction.Phase,
        cleanupSummary: String? = nil
    ) throws {
        var transaction = try requirePending(id: transactionID)
        transaction.phase = phase
        transaction.settledAt = Date()
        transaction.updatedAt = Date()
        if let cleanupSummary {
            transaction.cleanupSummary = cleanupSummary
        }
        try write(transaction)
    }

    private func write(_ transaction: SelfReplacementTransaction) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(transaction).write(to: fileURL, options: .atomic)
            try fileProtector.protect(fileURL)
        } catch {
            throw SelfReplacementStoreError.writeFailed
        }
    }
}

/// 仅用于迁移旧版 SelfSigningHandoff.json 的私有解码结构。
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
