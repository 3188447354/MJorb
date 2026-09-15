import Foundation
@preconcurrency import AltSign

enum SigningCertificateReuseStatus: Equatable, Sendable {
    case reusable
    case invalidValidity
    case insufficientLifetime
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
}
