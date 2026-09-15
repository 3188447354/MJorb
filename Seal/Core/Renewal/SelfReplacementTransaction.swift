import Foundation

struct SelfReplacementTransaction: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case prepared
        case submitting
        case awaitingReplacementConfirmation
        case installedOldIdentity
        case settling
        case confirmed
        case recoveryRequired
    }

    struct Submission: Codable, Equatable, Sendable {
        let id: UUID
        let claimedAt: Date
        var returnedAt: Date?
        var transportResult: String?
    }

    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    let accountID: UUID
    let preparedProcessID: UUID
    let installedBefore: InstalledIdentity
    let candidate: CandidateIdentity
    let signedIPARelativePath: String
    var phase: Phase
    var submission: Submission?
    var settledAt: Date?
    var failureCode: String?

    static func make(
        id: UUID,
        accountID: UUID,
        preparedProcessID: UUID,
        installedBefore: InstalledIdentity,
        candidate: CandidateIdentity,
        signedIPARelativePath: String,
        now: Date = Date()
    ) -> Self {
        Self(
            schemaVersion: 1,
            id: id,
            createdAt: now,
            updatedAt: now,
            accountID: accountID,
            preparedProcessID: preparedProcessID,
            installedBefore: installedBefore,
            candidate: candidate,
            signedIPARelativePath: signedIPARelativePath,
            phase: .prepared,
            submission: nil,
            settledAt: nil,
            failureCode: nil
        )
    }
}
