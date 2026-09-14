import Foundation

/// 一次「清理不可用证书」的决策结果。
///
/// 背景：自更新覆盖安装后 keychain 访问组随签名身份变化，历史 P12 私钥全部不可读；
/// Apple 侧只存公钥证书、不存私钥，于是账号下会累积多张「本机永远用不了」的证书，
/// 挤占证书名额直到撞上限。
///
/// 策略：一个 Apple ID 在本机只留一张可用证书。**所有本机无私钥的证书一律撤销**，
/// 不论设备端 profile 是否还在引用——留着也没法用它签新包，纯占名额。
/// 风险兜底：续签 Seal 时若 Seal 自身正用那张无钥匙证书跑着，撤完立即建新证重签重装，
/// 全程闭环；iOS 不会因证书被 Apple 撤销就立即杀进程（下次启动才校验），中间不闪退。
struct CertificateCleanupPlan: Equatable, Sendable {
    /// 可撤销的证书：本机无私钥的全部远端证书（不论是否仍被设备端 profile 引用）。
    let revocable: [ApplePortalCertificateSnapshot]
    /// 本机有私钥、可继续使用的证书。
    let kept: [ApplePortalCertificateSnapshot]
    /// 是否完成了设备端描述文件核验（保留字段，日志里用于区分信息完整度）。
    let deviceVerified: Bool
}

enum CertificateCleanupPolicy {
    /// 判定一张证书是否可撤销。所有序列号比较一律先归一化（坑位 1）。
    /// 归一化在比对点做、幂等：不依赖各调用方记得先处理，防止新来源忘归一化时
    /// 「有私钥」的证书因前导 0 差异误入可撤候选。
    ///
    /// 策略：一个 Apple ID 本机只留一张可用证书。**只要本机无私钥就可撤**，
    /// 不再区分「Seal 关联 App 在用」「设备端 profile 引用」——留着也没法用它
    /// 签新包，纯占名额。续签/签名流程闭环（撤 → 建 → 签 → 装），中间不闪退。
    static func makePlan(
        certificates: [ApplePortalCertificateSnapshot],
        apps: [AppRecord],
        localUsableSerials: Set<String>,
        deviceReferencedSerials: Set<String>?
    ) -> CertificateCleanupPlan {
        let normalizedLocalUsable = Set(localUsableSerials.map {
            SigningCertificateSelectionPolicy.normalizedSerialNumber($0)
        })
        var revocable: [ApplePortalCertificateSnapshot] = []
        var kept: [ApplePortalCertificateSnapshot] = []

        for certificate in certificates {
            let serial = SigningCertificateSelectionPolicy.normalizedSerialNumber(certificate.serialNumber)
            if normalizedLocalUsable.contains(serial) {
                kept.append(certificate)
            } else {
                revocable.append(certificate)
            }
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
