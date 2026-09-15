import Foundation

enum IdentityReadStatus: String, Codable, Sendable {
    case complete
    case unreadable
    case inconsistentArchitectures
    case signerNotAuthorizedByProfile
}

struct SignedTargetIdentity: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case mainApp, appExtension }
    let kind: Kind
    let bundleIdentifier: String
    let teamIdentifier: String
    let applicationIdentifier: String
    let profileUUID: String
    let profileExpirationDate: Date
    let signerSerialNumber: String
    let signerCertificateSHA256: String
    let status: IdentityReadStatus

    var isComplete: Bool { status == .complete }
}

struct InstalledIdentity: Codable, Equatable, Sendable {
    let bundleURL: URL
    let version: String
    let buildNumber: String
    let targets: [SignedTargetIdentity]
    let readErrors: [String]

    var mainTarget: SignedTargetIdentity? {
        targets.first { $0.kind == .mainApp }
    }

    var isComplete: Bool {
        readErrors.isEmpty && mainTarget != nil && targets.allSatisfy(\.isComplete)
    }

    static func unknown(bundleIdentifier: String) -> Self {
        Self(
            bundleURL: URL(fileURLWithPath: "/unknown/\(bundleIdentifier).app"),
            version: "",
            buildNumber: "",
            targets: [],
            readErrors: ["由旧版 handoff 迁移，缺少安装前真实身份快照"]
        )
    }
}

struct CandidateIdentity: Codable, Equatable, Sendable {
    let transactionID: UUID
    let ipaSHA256: String
    let version: String
    let buildNumber: String
    let targets: [SignedTargetIdentity]

    var mainBundleIdentifier: String {
        targets.first(where: { $0.kind == .mainApp })?.bundleIdentifier ?? ""
    }

    func matches(_ installed: InstalledIdentity) -> Bool {
        installed.isComplete
            && version == installed.version
            && buildNumber == installed.buildNumber
            && targets.sorted(by: Self.order) == installed.targets.sorted(by: Self.order)
    }

    private static func order(_ lhs: SignedTargetIdentity, _ rhs: SignedTargetIdentity) -> Bool {
        if lhs.bundleIdentifier != rhs.bundleIdentifier {
            return lhs.bundleIdentifier < rhs.bundleIdentifier
        }
        if lhs.kind != rhs.kind {
            return lhs.kind < rhs.kind
        }
        if lhs.teamIdentifier != rhs.teamIdentifier {
            return lhs.teamIdentifier < rhs.teamIdentifier
        }
        if lhs.applicationIdentifier != rhs.applicationIdentifier {
            return lhs.applicationIdentifier < rhs.applicationIdentifier
        }
        if lhs.profileUUID != rhs.profileUUID {
            return lhs.profileUUID < rhs.profileUUID
        }
        if lhs.profileExpirationDate != rhs.profileExpirationDate {
            return lhs.profileExpirationDate < rhs.profileExpirationDate
        }
        if lhs.signerSerialNumber != rhs.signerSerialNumber {
            return lhs.signerSerialNumber < rhs.signerSerialNumber
        }
        if lhs.signerCertificateSHA256 != rhs.signerCertificateSHA256 {
            return lhs.signerCertificateSHA256 < rhs.signerCertificateSHA256
        }
        return lhs.status < rhs.status
    }

    static func legacy(
        transactionID: UUID,
        bundleIdentifier: String,
        teamIdentifier: String,
        profileUUID: String,
        certificateSerialNumber: String
    ) -> Self {
        Self(
            transactionID: transactionID,
            ipaSHA256: "",
            version: "",
            buildNumber: "",
            targets: [.init(
                kind: .mainApp,
                bundleIdentifier: bundleIdentifier,
                teamIdentifier: teamIdentifier,
                applicationIdentifier: "",
                profileUUID: profileUUID,
                profileExpirationDate: .distantPast,
                signerSerialNumber: certificateSerialNumber,
                signerCertificateSHA256: "",
                status: .unreadable
            )]
        )
    }
}

struct LocalSigningIdentity: Codable, Equatable, Sendable {
    let accountID: UUID
    let teamIdentifier: String
    let certificateSerialNumber: String
    let certificateSHA256: String
    let expirationDate: Date
    let hasMatchingPrivateKey: Bool

    var isUsable: Bool {
        hasMatchingPrivateKey && expirationDate > Date()
    }
}

enum SelfManagementState: String, Codable, Sendable {
    case externalBootstrap
    case preparingLocalIdentity
    case localIdentityReady
    case awaitingReplacementConfirmation
    case selfManaged
    case recoveryRequired
}

enum SelfReplacementProcess {
    static let currentID = UUID()
}
