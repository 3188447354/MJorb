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

    /// 身份读取失败时的可读诊断摘要（每个非 complete 目标的状态 + readErrors），
    /// 用于日志与错误文案定位「主程序还是扩展、描述文件问题还是 CMS 签名问题」。
    var readFailureSummary: String {
        var parts: [String] = []
        for target in targets where !target.isComplete {
            let label = target.kind == .mainApp
                ? "主程序(\(target.bundleIdentifier))"
                : "扩展(\(target.bundleIdentifier))"
            parts.append("\(label)=\(target.status.rawValue)")
        }
        parts.append(contentsOf: readErrors)
        return parts.isEmpty ? "未知" : parts.joined(separator: " | ")
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
            return lhs.kind.rawValue < rhs.kind.rawValue
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
        return lhs.status.rawValue < rhs.status.rawValue
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
