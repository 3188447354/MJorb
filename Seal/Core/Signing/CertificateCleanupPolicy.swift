import Foundation

/// 一次「清理不可用证书」的决策结果。
///
/// 背景：自更新覆盖安装后 keychain 访问组随签名身份变化，历史 P12 私钥全部不可读；
/// Apple 侧只存公钥证书、不存私钥，于是账号下会累积多张「本机永远用不了」的证书，
/// 挤占证书名额直到撞上限。撤销是唯一出路，但撤销仍被已安装 App 使用的证书会让
/// 该 App 立即闪退 —— 因此候选必须同时满足四重条件，缺一不可。
struct CertificateCleanupPlan: Equatable, Sendable {
    /// 可安全撤销的证书：本机无私钥 ∧ 无关联已安装 App ∧ 设备端描述文件未引用。
    let revocable: [ApplePortalCertificateSnapshot]
    /// 仍被使用而必须保留的证书（本机有私钥、已安装 App 在用、或设备端 profile 引用）。
    let kept: [ApplePortalCertificateSnapshot]
    /// 是否完成了设备端描述文件核验。
    /// false（未连接设备/隧道不可用）时结论仅基于本机记录，UI 必须明示降级：
    /// 其他签名工具用同一 Apple ID 安装的 App 不在本机记录内，撤销其证书会让它们失效。
    let deviceVerified: Bool
}

enum CertificateCleanupPolicy {
    /// 判定一张证书是否可安全撤销。所有序列号比较一律先归一化（坑位 1）。
    static func makePlan(
        certificates: [ApplePortalCertificateSnapshot],
        apps: [AppRecord],
        localUsableSerials: Set<String>,
        deviceReferencedSerials: Set<String>?
    ) -> CertificateCleanupPlan {
        var revocable: [ApplePortalCertificateSnapshot] = []
        var kept: [ApplePortalCertificateSnapshot] = []

        for certificate in certificates {
            let serial = SigningCertificateSelectionPolicy.normalizedSerialNumber(certificate.serialNumber)
            if localUsableSerials.contains(serial) {
                kept.append(certificate)
                continue
            }
            // 只拦「已安装」的：未安装的包重签一次即可，撤销证书不会造成实际损失
            // （与 CertificateRevocationImpact.warningMessage 的口径一致）。
            if CertificateRevocationImpact.affectedApps(
                serialNumber: certificate.serialNumber,
                apps: apps
            ).isEmpty == false {
                kept.append(certificate)
                continue
            }
            if let deviceReferencedSerials, deviceReferencedSerials.contains(serial) {
                kept.append(certificate)
                continue
            }
            revocable.append(certificate)
        }

        return CertificateCleanupPlan(
            revocable: revocable,
            kept: kept,
            deviceVerified: deviceReferencedSerials != nil
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
        certificates.filter {
            localUsableSerials.contains(
                SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber)
            ) == false
        }
    }
}
