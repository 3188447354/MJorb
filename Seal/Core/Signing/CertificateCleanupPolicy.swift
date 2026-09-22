import Foundation

/// 自动清理只处理本机无私钥、已核验无本机应用引用的候选。
/// 无私钥不等于无用途；Seal 真实签名者、其他已装 App、设备 profile 的引用均须保留。
struct CertificateCleanupPlan: Equatable, Sendable {
    let revocable: [ApplePortalCertificateSnapshot]
    /// 保留不代表有私钥，也可能是仍在使用或设备核验不可用。
    let kept: [ApplePortalCertificateSnapshot]
    let deviceVerified: Bool
    let localPrivateKeyCount: Int
    let protectedSealWithoutKeyCount: Int
    /// 非 nil 表示计划被阻断：真实签名者不可确认，任何证书都不得撤销。
    let blockedReason: String?
    /// 生成计划时读到的真实签名者。执行撤销前必须重读身份比对：
    /// signer 变了说明这段时间内 Seal 被换签，原计划作废，整批停止。
    let sealActualSignerSerialNumber: String?

    /// 真实签名者读不出来时的安全姿态：一张都不撤。
    /// Seal 的命（A）可能就在清单里，无法确认时动任何一张都可能变砖。
    static func blocked(reason: String) -> CertificateCleanupPlan {
        CertificateCleanupPlan(
            revocable: [],
            kept: [],
            deviceVerified: false,
            localPrivateKeyCount: 0,
            protectedSealWithoutKeyCount: 0,
            blockedReason: reason,
            sealActualSignerSerialNumber: nil
        )
    }
}

enum CertificateCleanupPolicy {
    /// 所有来源在比对点归一化。Seal 保护只认主程序的真实 CMS 签名者，
    /// 不认描述文件授权列表——授权 ≠ 实际签名（Task 10）。
    static func makePlan(
        certificates: [ApplePortalCertificateSnapshot],
        apps: [AppRecord],
        localUsableSerials: Set<String>,
        deviceReferencedSerials: Set<String>?,
        sealActualSignerSerialNumber: String?,
        identityConfidence: IdentityReadStatus
    ) -> CertificateCleanupPlan {
        guard identityConfidence == .complete,
              let sealActualSignerSerialNumber,
              SigningCertificateSelectionPolicy.normalizedSerialNumber(sealActualSignerSerialNumber).isEmpty == false
        else {
            return .blocked(reason: "无法确认当前 Seal 的真实签名证书")
        }
        let normalizedLocalUsable = Set(localUsableSerials.map {
            SigningCertificateSelectionPolicy.normalizedSerialNumber($0)
        })
        let normalizedSealSigner = SigningCertificateSelectionPolicy.normalizedSerialNumber(
            sealActualSignerSerialNumber
        )
        let deviceSerials = Set((deviceReferencedSerials ?? []).map {
            SigningCertificateSelectionPolicy.normalizedSerialNumber($0)
        })
        let installedApps = apps.filter { $0.state == .installed || $0.isSeal }
        let appSerials = Set((installedApps.compactMap(\.certificateSerialNumber)
            + installedApps.flatMap { $0.signingTargets.flatMap(\.certificateSerialNumbers) }).map {
            SigningCertificateSelectionPolicy.normalizedSerialNumber($0)
        })
        let hasUnknownInstalledIdentity = installedApps.contains {
            $0.certificateSerialNumber.map {
                SigningCertificateSelectionPolicy.normalizedSerialNumber($0).isEmpty
            } ?? true
        }
        var revocable: [ApplePortalCertificateSnapshot] = []
        var kept: [ApplePortalCertificateSnapshot] = []
        var localPrivateKeyCount = 0
        var protectedSealWithoutKeyCount = 0

        for certificate in certificates {
            let serial = SigningCertificateSelectionPolicy.normalizedSerialNumber(certificate.serialNumber)
            if normalizedLocalUsable.contains(serial) {
                kept.append(certificate)
                localPrivateKeyCount += 1
            } else if serial == normalizedSealSigner {
                kept.append(certificate)
                protectedSealWithoutKeyCount += 1
            } else if deviceReferencedSerials == nil || hasUnknownInstalledIdentity
                        || appSerials.contains(serial) || deviceSerials.contains(serial) {
                kept.append(certificate)
            } else {
                revocable.append(certificate)
            }
        }

        return CertificateCleanupPlan(
            revocable: revocable,
            kept: kept,
            deviceVerified: deviceReferencedSerials != nil,
            localPrivateKeyCount: localPrivateKeyCount,
            protectedSealWithoutKeyCount: protectedSealWithoutKeyCount,
            blockedReason: nil,
            sealActualSignerSerialNumber: sealActualSignerSerialNumber
        )
    }

    /// 签名失败页「撤销并继续签名」（SEAL-CERT-204e）经用户明确确认后的候选：
    /// 账号下**所有本机无私钥**的远端证书，不论是否仍在使用。
    /// 与 `makePlan` 的区别仅在这一步 —— 是否忽略「在用」状态；静默自动清理永远走
    /// `makePlan`，本函数只允许出现在用户确认之后。
    static func sacrificeCandidates(
        certificates: [ApplePortalCertificateSnapshot],
        localUsableSerials: Set<String>
    ) -> [ApplePortalCertificateSnapshot] {
        let normalizedLocalUsable = Set(localUsableSerials.map {
            SigningCertificateSelectionPolicy.normalizedSerialNumber($0)
        })
        return certificates.filter {
            normalizedLocalUsable.contains(
                SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber)
            ) == false
        }
    }
}
