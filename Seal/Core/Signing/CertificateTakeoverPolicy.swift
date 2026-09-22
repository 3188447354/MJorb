import Foundation

/// 接管证书槽位时的决策。真实签名者 A 永远不能成为撤销候选：
/// 撤了 A，当前运行的 Seal 立刻「不再可用」。
///
/// 注：本策略是单槽位接管的验收规格（被 verify-release-safety.py 与
/// CertificateTakeoverPolicyTests 断言）；运行时实际由
/// `SigningCertificateMaterialPolicy.rotationCandidates`（ApplePortalSigningService
/// 慢速路径）驱动。二者必须保持同义：空槽位直接建、满槽位只撤销非 A、签名者未知即阻断。
/// 改动任何一侧都要同步另一侧，避免规格与运行时漂移。
enum CertificateTakeoverDecision: Equatable, Sendable {
    /// 本机已有仍在 Apple 生效列表里的可用私钥证书，直接复用。
    case reuseLocal(serialNumber: String)
    /// 槽位未满，直接创建本机身份。
    case createLocal
    /// 槽位已满：只有这些「非 A」证书可以在用户确认后撤销。
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
        let candidates = remoteSerialNumbers.filter { normalize($0) != protected }
        guard candidates.isEmpty == false else {
            return .blocked(reason: "没有可以安全释放的证书槽位")
        }
        return .requestRevocation(candidateSerialNumbers: candidates)
    }
}
