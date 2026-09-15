import Foundation

/// 旧版 handoff 记录，仅用于兼容迁移。新代码请使用 SelfReplacementTransactionStore。
/// 独立于 AppRecord 保存，避免自注册重建记录时丢失安装前的核验目标。
/// 不包含 Apple ID、P12 或私钥；确认只证明本机材料可用，不代表 Apple 远端仍生效。
struct SelfSigningHandoff: Codable, Equatable, Sendable {
    var id = UUID()
    let accountID: UUID
    let bundleIdentifier: String
    let teamIdentifier: String
    let profileUUID: String
    let certificateSerialNumber: String
    let preparedInProcess: UUID
    var confirmedAt: Date? = nil
}

enum SelfSigningHandoffMaterialStatus: Sendable {
    case available
    case missingPrivateKey
    case unusableCertificate
}

enum SelfSigningHandoffStatus: Equatable, Sendable {
    case noPending
    case awaitingRestart
    case superseded
    case bundleMismatch
    case teamMismatch
    case profileMismatch
    case certificateMismatch
    case missingPrivateKey
    case unusableCertificate
    case confirmed

    var message: String {
        switch self {
        case .noPending: "没有待核验的本机签名身份"
        case .awaitingRestart: "已保存本机签名核验目标，等待安装后重新启动 Seal"
        case .superseded: "本机签名核验目标已更新，保留新目标等待核验"
        case .bundleMismatch: "当前运行的 Seal Bundle ID 与待核验目标不符，尚未确认接管"
        case .teamMismatch: "当前运行包签名团队与待核验目标不符，尚未确认接管"
        case .profileMismatch: "当前运行包仍未使用预期描述文件，保留待核验记录"
        case .certificateMismatch: "当前运行包描述文件未授权预期证书，尚未确认接管"
        case .missingPrivateKey: "当前运行包已匹配，但本机缺少可解析且私钥匹配的签名材料；请检查账号签名材料，必要时通过电脑恢复"
        case .unusableCertificate: "当前运行包已匹配，但本机证书有效期无法核验或剩余不足 7 天，尚未确认本机续签能力"
        case .confirmed: "重启核验通过：运行包团队、描述文件和授权证书匹配，本机私钥可用且证书剩余有效期超过 7 天"
        }
    }
}

enum SelfSigningHandoffPolicy {
    static func evaluate(
        pending: SelfSigningHandoff,
        metadata: SelfAppMetadata,
        materialStatus: SelfSigningHandoffMaterialStatus
    ) -> SelfSigningHandoffStatus {
        guard metadata.bundleIdentifier == pending.bundleIdentifier else { return .bundleMismatch }
        guard metadata.signingTeamIdentifier?.caseInsensitiveCompare(pending.teamIdentifier) == .orderedSame else {
            return .teamMismatch
        }
        guard metadata.provisioningProfileUUID?.caseInsensitiveCompare(pending.profileUUID) == .orderedSame else {
            return .profileMismatch
        }
        let serial = SigningCertificateSelectionPolicy.normalizedSerialNumber(pending.certificateSerialNumber)
        guard !serial.isEmpty, metadata.certificateSerialNumbers.contains(where: {
            SigningCertificateSelectionPolicy.normalizedSerialNumber($0) == serial
        }) else { return .certificateMismatch }
        switch materialStatus {
        case .available: return .confirmed
        case .missingPrivateKey: return .missingPrivateKey
        case .unusableCertificate: return .unusableCertificate
        }
    }
}

actor SelfSigningHandoffStore {
    // 同一进程即使重新构造容器也不能冒充重启；测试可显式注入不同启动身份。
    static let currentProcessIdentifier = UUID()
    private let fileURL: URL
    private let fileProtector: any FileProtecting
    private let processIdentifier: UUID

    init(
        fileURL: URL,
        processIdentifier: UUID = SelfSigningHandoffStore.currentProcessIdentifier,
        fileProtector: any FileProtecting = CompleteFileProtector()
    ) {
        self.fileURL = fileURL
        self.processIdentifier = processIdentifier
        self.fileProtector = fileProtector
    }

    /// 必须在安装开始前 await 成功；写入失败不得继续自更新。
    func prepare(
        accountID: UUID,
        bundleIdentifier: String,
        teamIdentifier: String,
        profileUUID: String,
        certificateSerialNumber: String
    ) throws {
        guard !bundleIdentifier.isEmpty, !teamIdentifier.isEmpty, !profileUUID.isEmpty,
              !SigningCertificateSelectionPolicy.normalizedSerialNumber(certificateSerialNumber).isEmpty else {
            throw ImportFailure(title: "无法准备本机签名核验", reason: "签名包缺少完整的团队、描述文件或证书身份。", recovery: "重新签名后重试", code: "SEAL-CERT-222")
        }
        try write(SelfSigningHandoff(
            accountID: accountID,
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier,
            profileUUID: profileUUID,
            certificateSerialNumber: certificateSerialNumber,
            preparedInProcess: processIdentifier
        ))
    }

    func loadPending() throws -> SelfSigningHandoff? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let record = try JSONDecoder().decode(SelfSigningHandoff.self, from: Data(contentsOf: fileURL))
        return record.confirmedAt == nil ? record : nil
    }

    /// 调用者读取钥匙串会让出 actor，故再次核对 ID；绝不覆盖新一轮安装的目标。
    func confirm(
        metadata: SelfAppMetadata,
        pendingID: UUID,
        materialStatus: SelfSigningHandoffMaterialStatus
    ) throws -> SelfSigningHandoffStatus {
        guard var pending = try loadPending() else { return .noPending }
        guard pending.id == pendingID else { return .superseded }
        guard pending.preparedInProcess != processIdentifier else { return .awaitingRestart }
        let status = SelfSigningHandoffPolicy.evaluate(pending: pending, metadata: metadata, materialStatus: materialStatus)
        if status == .confirmed {
            pending.confirmedAt = Date()
            try write(pending)
        }
        return status
    }

    private func write(_ record: SelfSigningHandoff) throws {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: fileURL, options: .atomic)
            try fileProtector.protect(fileURL)
        } catch {
            throw ImportFailure(title: "无法保存本机签名核验", reason: "本地核验记录写入失败，无法可靠确认自更新结果。", recovery: "检查设备剩余空间，重新打开 Seal 后重试", code: "SEAL-CERT-223")
        }
    }
}
