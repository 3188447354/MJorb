import Foundation

/// 接管证书槽位时的决策。真实签名者 A **只能排在最后**，**不能排除**。
///
/// 🔴 「排除 A」曾把免费账号变成永久死锁（2026-09-26，构建 47 真机）：
/// 免费团队只有一个活动槽位，而 Seal 自己的证书在覆盖安装后必然丢失本机私钥
/// ⇒ A 往往是**唯一**候选 ⇒ 排除它 ⇒ 再也建不出新证书
/// ⇒ 签任何 App 都报 `SEAL-CERT-204b`（3022 名额满），用户「啥也干不了」。
/// ⇒ 正确做法是**先撤普通证书、别无选择才动 A**，把 Seal 失去签名身份的窗口缩到最小；
/// 撤销后的恢复由 `resignAppsAffectedByCertificateRotation(includeSeal: true)` 负责。
///
/// 注：本策略是单槽位接管的验收规格（被 verify-release-safety.py 与
/// CertificateTakeoverPolicyTests 断言）；运行时实际由
/// `SigningCertificateMaterialPolicy.rotationCandidates`（ApplePortalSigningService
/// 慢速路径）驱动。二者必须保持同义：空槽位直接建、满槽位**先撤普通证书、A 排最后**、
/// 签名者未知即阻断。改动任何一侧都要同步另一侧，避免规格与运行时漂移。
enum CertificateTakeoverDecision: Equatable, Sendable {
    /// 本机已有仍在 Apple 生效列表里的可用私钥证书，直接复用。
    case reuseLocal(serialNumber: String)
    /// 槽位未满，直接创建本机身份。
    case createLocal
    /// 槽位已满：这些证书可以在用户确认后撤销（普通证书在前，运行中 Seal 的 A 排最后）。
    case requestRevocation(candidateSerialNumbers: [String])
    /// 真实签名者不可确认或没有可安全释放的槽位：禁止任何动作。
    case blocked(reason: String)
}

enum CertificateTakeoverPolicy {
    private static func normalize(_ value: String) -> String {
        SigningCertificateSelectionPolicy.normalizedSerialNumber(value)
    }

    /// 空槽位与满槽位的接管决策。所有序列号在比对点归一化（坑位 1）。
    /// 免费团队只有一个「活动 iOS 开发证书」槽位（Apple 硬限制，非两个），
    /// 所以 maximumCertificates 恒为 1：有远程证书且不可复用即先撤销再创建。
    static func decide(
        remoteSerialNumbers: [String],
        localUsableSerialNumbers: Set<String>,
        actualSealSignerSerialNumber: String?,
        identityComplete: Bool,
        maximumCertificates: Int = 1
    ) -> CertificateTakeoverDecision {
        guard identityComplete,
              let actualSealSignerSerialNumber,
              normalize(actualSealSignerSerialNumber).isEmpty == false else {
            return .blocked(reason: "无法确认当前 Seal 的真实签名证书")
        }
        if let local = remoteSerialNumbers.first(where: {
            localUsableSerialNumbers.contains(normalize($0))
        }) {
            return .reuseLocal(serialNumber: local)
        }
        if remoteSerialNumbers.count < maximumCertificates { return .createLocal }
        let protected = normalize(actualSealSignerSerialNumber)
        // A **可以**是撤销候选，但必须排在最后（见文件头注释：排除 A = 免费账号永久死锁）。
        let ordinaryCandidates = remoteSerialNumbers.filter { normalize($0) != protected }
        let runningSealCandidates = remoteSerialNumbers.filter { normalize($0) == protected }
        let ordered = ordinaryCandidates + runningSealCandidates
        guard ordered.isEmpty == false else {
            return .blocked(reason: "没有可以安全释放的证书槽位")
        }
        return .requestRevocation(candidateSerialNumbers: ordered)
    }
}
