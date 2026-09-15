import CryptoKit
import Foundation
import ZIPFoundation

/// 从候选 IPA 中读取主程序与所有扩展的真实签名身份，并生成 CandidateIdentity。
struct SignedIPAIdentityReader: Sendable {
    let bundleReader: AppBundleSigningIdentityReader

    func read(ipaData: Data, transactionID: UUID) throws -> CandidateIdentity {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SealCandidate-\(transactionID.uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ipaURL = root.appending(path: "Candidate.ipa")
        let unpacked = root.appending(path: "Unpacked", directoryHint: .isDirectory)
        try ipaData.write(to: ipaURL, options: .atomic)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: ipaURL, to: unpacked)
        let payload = unpacked.appending(path: "Payload", directoryHint: .isDirectory)
        let apps = try FileManager.default.contentsOfDirectory(
            at: payload,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "app" }
        guard apps.count == 1 else { throw IdentityReadFailure.invalidIPA }
        let installedShape = try bundleReader.read(bundleURL: apps[0])
        guard installedShape.isComplete else { throw IdentityReadFailure.incompleteIdentity }
        let serials = Set(installedShape.targets.map(\.signerSerialNumber))
        guard serials.count == 1 else { throw IdentityReadFailure.targetSignerMismatch }
        return CandidateIdentity(
            transactionID: transactionID,
            ipaSHA256: SHA256.hash(data: ipaData).map { String(format: "%02X", $0) }.joined(),
            version: installedShape.version,
            buildNumber: installedShape.buildNumber,
            targets: installedShape.targets
        )
    }
}
