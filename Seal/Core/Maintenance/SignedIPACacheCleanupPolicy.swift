import Foundation

/// Determines whether a regenerable Signed.ipa cache is safe to release.
/// It deliberately keeps cache needed to finish or diagnose an in-flight install.
enum SignedIPACacheCleanupPolicy {
    enum ProtectionReason: Equatable, Sendable {
        case awaitingVerification
        case installFailed
        case pendingTransaction
        case pendingUpdateSource
        case notInstalled
        case noCache
    }

    enum Decision: Equatable, Sendable {
        case reclaimable
        case protected(ProtectionReason)
    }

    static func decision(for app: AppRecord) -> Decision {
        guard app.hasSignedArtifact else { return .protected(.noCache) }
        guard app.pendingSignedSnapshot == nil else { return .protected(.pendingTransaction) }
        guard app.hasPendingSelfUpdateSource == false else { return .protected(.pendingUpdateSource) }
        switch app.signedArtifactStatus {
        case .awaitingVerification:
            return .protected(.awaitingVerification)
        case .installFailed:
            return .protected(.installFailed)
        default:
            break
        }
        guard app.state == .installed, app.signedArtifactStatus == .installed else {
            return .protected(.notInstalled)
        }
        return .reclaimable
    }
}
