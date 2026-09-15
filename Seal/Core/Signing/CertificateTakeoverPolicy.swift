import Foundation

/// 接管证书槽位时的决策。真实签名者 A 永远不能成为撤销候选：
/// 撤了 A，当前运行的 Seal 立刻「不再可用」。
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
    static func decide(
        remoteSerialNumbers: [String],
        localUsableSerialNumbers: Set<String>,
        actualSealSignerSerialNumber: String?,
        identityComplete: Bool,
        maximumCertificates: Int = 2
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
