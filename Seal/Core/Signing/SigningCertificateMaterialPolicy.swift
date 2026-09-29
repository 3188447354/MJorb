import Foundation
@preconcurrency import AltSign

enum SigningCertificateReuseStatus: Equatable, Sendable {
    case reusable
    case invalidValidity
    case insufficientLifetime
}

/// 快速路径两支的复用判定结果。抽成独立类型，让 `signingIdentity`（actor private + 含网络）
/// 无法单测的分支选择落成可单测的纯函数（见 `fastPathReuseDecision`，R102）。
enum FastPathCertificateReuseDecision: Equatable, Sendable {
    /// 证书仍在 Apple 生效列表 && 剩余有效期覆盖 7 天 profile 寿命 → 复用。
    case reuseFromActiveList
    /// Apple 证书列表拉取失败（限流/超时/网络）→ 退回本地证书，但仍须过 7 天校验。
    case reuseLocalWithoutList
    /// 落回慢速路径（重新申请证书）。
    case fallThroughToSlowPath
}

enum SigningCertificateRotationReason: Equatable, Sendable {
    case missingPrivateKey
    case insufficientLifetime
    case invalidValidity
}

struct SigningCertificateRotationCandidate: Equatable, Sendable {
    let serialNumber: String
    let reason: SigningCertificateRotationReason
    let isRunningSealCertificate: Bool
}

/// 清理只能判断是否有私钥；签名还必须检查该私钥对应证书的有效期。
/// 有材料但暂时不可复用的证书不能被当成孤儿自动撤销。
enum SigningCertificateMaterialPolicy {
    static let minimumRemainingLifetime: TimeInterval = 7 * 24 * 3600

    static func externalSealSerial(
        isSeal: Bool,
        teamID: String,
        runningTeamID: String?,
        runningSerials: [String],
        remoteSerials: [String],
        localPrivateKeySerials: Set<String>,
        expectedSerialNumber: String? = nil
    ) -> String? {
        guard isSeal, runningTeamID == teamID else { return nil }
        let normalize = SigningCertificateSelectionPolicy.normalizedSerialNumber
        let running = Set(runningSerials.map(normalize)).subtracting([""])
        let local = Set(localPrivateKeySerials.map(normalize))
        if let expectedSerialNumber, !expectedSerialNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !running.contains(normalize(expectedSerialNumber)) { return nil }
        return remoteSerials.first { running.contains(normalize($0)) && !local.contains(normalize($0)) }
    }

    static func availableCertificate(secret: AccountSecret, serialNumber: String) -> ALTCertificate? {
        guard let data = secret.p12(for: serialNumber),
              let certificate = try? ALTCertificate(p12Data: data, password: nil),
              !certificate.privateKey.isEmpty,
              SigningCertificateSelectionPolicy.normalizedSerialNumber(certificate.serialNumber)
                == SigningCertificateSelectionPolicy.normalizedSerialNumber(serialNumber) else { return nil }
        return certificate
    }

    static func reuseStatus(_ certificate: ALTCertificate, now: Date = Date()) -> SigningCertificateReuseStatus {
        reuseStatus(validity: certificate.data.flatMap(X509CertificateValidityReader.validity(from:)), now: now)
    }

    static func reuseStatus(validity: X509CertificateValidity?, now: Date = Date()) -> SigningCertificateReuseStatus {
        guard let validity, validity.notBefore <= now, validity.notAfter > validity.notBefore else {
            return .invalidValidity
        }
        return validity.notAfter.timeIntervalSince(now) > minimumRemainingLifetime
            ? .reusable : .insufficientLifetime
    }

    /// 快速路径两支的复用判定（纯函数，供单测 + R102 守卫钉住）。
    /// - `remoteSerials == nil`：列表拉取失败 → 只要本地证书可复用就回退复用（保留提速）。
    /// - `remoteSerials != nil`：列表拉到了 → 必须「serial 仍在生效列表」**且**「可复用」才复用。
    /// 两条路都不能只判「当下未过期」—— 剩余寿命须覆盖免费 profile 的 7 天（见 `reuseStatus`）。
    static func fastPathReuseDecision(
        remoteSerials: [String]?,
        targetSerialNumber: String,
        reuseStatus: SigningCertificateReuseStatus
    ) -> FastPathCertificateReuseDecision {
        guard reuseStatus == .reusable else { return .fallThroughToSlowPath }
        if let remoteSerials {
            let normalized = SigningCertificateSelectionPolicy.normalizedSerialNumber(targetSerialNumber)
            let inActiveList = remoteSerials.contains {
                SigningCertificateSelectionPolicy.normalizedSerialNumber($0) == normalized
            }
            return inActiveList ? .reuseFromActiveList : .fallThroughToSlowPath
        }
        return .reuseLocalWithoutList
    }

    /// Apple 明确返回证书名额上限后，只轮换已经不能覆盖一份新 7 天描述文件的证书。
    /// 优先释放日期无效、寿命不足和无私钥的普通证书；当前运行中的 Seal 证书排到最后，
    /// 尽量把 Seal 失去旧签名身份到新包安装完成之间的窗口缩到最小。
    static func rotationCandidates(
        remoteSerialNumbers: [String],
        reuseStatusBySerial: [String: SigningCertificateReuseStatus],
        runningSealSerialNumbers: Set<String>
    ) -> [SigningCertificateRotationCandidate] {
        let normalizedRunningSeal = Set(runningSealSerialNumbers.map {
            SigningCertificateSelectionPolicy.normalizedSerialNumber($0)
        })
        let normalizedStatuses = reuseStatusBySerial.reduce(into: [String: SigningCertificateReuseStatus]()) {
            result, entry in
            result[SigningCertificateSelectionPolicy.normalizedSerialNumber(entry.key)] = entry.value
        }
        return remoteSerialNumbers.compactMap { serial -> SigningCertificateRotationCandidate? in
            let normalized = SigningCertificateSelectionPolicy.normalizedSerialNumber(serial)
            let reason: SigningCertificateRotationReason
            switch normalizedStatuses[normalized] {
            case .reusable: return nil
            case .insufficientLifetime: reason = .insufficientLifetime
            case .invalidValidity: reason = .invalidValidity
            case nil: reason = .missingPrivateKey
            }
            return SigningCertificateRotationCandidate(
                serialNumber: serial,
                reason: reason,
                isRunningSealCertificate: normalizedRunningSeal.contains(normalized)
            )
        }.sorted { lhs, rhs in
            let lhsRank = rotationRank(lhs)
            let rhsRank = rotationRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.serialNumber < rhs.serialNumber
        }
    }

    private static func rotationRank(_ candidate: SigningCertificateRotationCandidate) -> Int {
        if candidate.isRunningSealCertificate { return 3 }
        switch candidate.reason {
        case .invalidValidity: return 0
        case .insufficientLifetime: return 1
        case .missingPrivateKey: return 2
        }
    }
}
