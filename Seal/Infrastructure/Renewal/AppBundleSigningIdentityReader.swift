import Foundation
import RorkSign

/// 描述文件授权证书与实际 CMS 签名者不一致时的读取结果。
/// 真实签名者必须来自 Mach-O 内嵌 CMS，而不是描述文件第一张证书。
enum IdentityReadFailure: Error, Equatable, Sendable {
    case signerMissing
    case inconsistentArchitectures
    case signerNotAuthorizedByProfile
    case invalidIPA
    case incompleteIdentity
    case targetSignerMismatch
}

struct ExecutableSignerEvidence: Equatable, Sendable {
    let serialNumber: String
    let cmsValid: Bool
    let codeDirectoryValid: Bool
}

/// 读取已安装 App Bundle（含主程序和 PlugIns/*.appex）的真实签名身份。
struct AppBundleSigningIdentityReader: Sendable {
    typealias Inspector = @Sendable (URL) throws -> ExecutableSignerEvidence
    private let inspectExecutable: Inspector

    init(inspectExecutable: @escaping Inspector = Self.inspectWithRorkSign) {
        self.inspectExecutable = inspectExecutable
    }

    private static func inspectWithRorkSign(_ executableURL: URL) throws -> ExecutableSignerEvidence {
        let reports = try RorkSigner.checkMachOCodeSignatures(at: executableURL)
        guard reports.isEmpty == false,
              let serial = reports.first?.signingCertificate?.serialNumberHex else {
            throw IdentityReadFailure.signerMissing
        }
        let normalized = SigningCertificateSelectionPolicy.normalizedSerialNumber(serial)
        guard reports.allSatisfy({
            $0.cmsSignatureValid
                && $0.codeDirectoryHashesValid
                && SigningCertificateSelectionPolicy.normalizedSerialNumber(
                    $0.signingCertificate?.serialNumberHex ?? ""
                ) == normalized
        }) else {
            throw IdentityReadFailure.inconsistentArchitectures
        }
        return ExecutableSignerEvidence(
            serialNumber: normalized,
            cmsValid: true,
            codeDirectoryValid: true
        )
    }

    /// 读取主程序与所有扩展，返回带 readErrors 的 InstalledIdentity；任何一步失败都记录到对应 target 的 status。
    func read(bundleURL: URL) throws -> InstalledIdentity {
        var targets: [SignedTargetIdentity] = []
        var readErrors: [String] = []

        // 主程序
        do {
            let target = try readTarget(bundleURL: bundleURL, kind: .mainApp)
            targets.append(target)
        } catch let failure as IdentityReadFailure {
            targets.append(makeUnreadableTarget(
                bundleURL: bundleURL, kind: .mainApp, status: status(for: failure)
            ))
            readErrors.append("main: \(failure)")
        } catch {
            targets.append(makeUnreadableTarget(
                bundleURL: bundleURL, kind: .mainApp, status: .unreadable
            ))
            readErrors.append("main: \(error)")
        }

        // 扩展：只枚举 PlugIns/*.appex，按 Bundle ID 排序
        let pluginsURL = bundleURL.appending(path: "PlugIns", directoryHint: .isDirectory)
        if let appexURLs = try? FileManager.default.contentsOfDirectory(
            at: pluginsURL,
            includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "appex" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            for appexURL in appexURLs {
                do {
                    let target = try readTarget(bundleURL: appexURL, kind: .appExtension)
                    targets.append(target)
                } catch let failure as IdentityReadFailure {
                    targets.append(makeUnreadableTarget(
                        bundleURL: appexURL, kind: .appExtension, status: status(for: failure)
                    ))
                    readErrors.append("extension \(appexURL.lastPathComponent): \(failure)")
                } catch {
                    targets.append(makeUnreadableTarget(
                        bundleURL: appexURL, kind: .appExtension, status: .unreadable
                    ))
                    readErrors.append("extension \(appexURL.lastPathComponent): \(error)")
                }
            }
        }

        let info = try? PropertyListSerialization.propertyList(
            from: Data(contentsOf: bundleURL.appending(path: "Info.plist")),
            format: nil
        ) as? [String: Any]
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let buildNumber = info?["CFBundleVersion"] as? String ?? ""

        return InstalledIdentity(
            bundleURL: bundleURL,
            version: version,
            buildNumber: buildNumber,
            targets: targets,
            readErrors: readErrors
        )
    }

    private func readTarget(bundleURL: URL, kind: SignedTargetIdentity.Kind) throws -> SignedTargetIdentity {
        let infoURL = bundleURL.appending(path: "Info.plist")
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoURL), format: nil
        ) as? [String: Any]
        let bundleID = try requiredString("CFBundleIdentifier", in: info)
        let executableName = try requiredString("CFBundleExecutable", in: info)
        let profileData = try Data(contentsOf: bundleURL.appending(path: "embedded.mobileprovision"))
        let profile = try ProvisioningProfileReader().details(from: profileData)
        let evidence = try inspectExecutable(bundleURL.appending(path: executableName))
        let normalizedEvidenceSerial = SigningCertificateSelectionPolicy.normalizedSerialNumber(evidence.serialNumber)
        let signer = profile.developerCertificates.first {
            SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber)
                == normalizedEvidenceSerial
        }
        guard let signer else {
            throw IdentityReadFailure.signerNotAuthorizedByProfile
        }
        return SignedTargetIdentity(
            kind: kind,
            bundleIdentifier: bundleID,
            teamIdentifier: profile.teamIdentifier ?? "",
            applicationIdentifier: profile.applicationIdentifier ?? "",
            profileUUID: profile.uuid ?? "",
            profileExpirationDate: profile.expirationDate ?? .distantPast,
            signerSerialNumber: signer.serialNumber,
            signerCertificateSHA256: signer.sha256Fingerprint,
            status: .complete
        )
    }

    private func makeUnreadableTarget(
        bundleURL: URL,
        kind: SignedTargetIdentity.Kind,
        status: IdentityReadStatus
    ) -> SignedTargetIdentity {
        let info = try? PropertyListSerialization.propertyList(
            from: Data(contentsOf: bundleURL.appending(path: "Info.plist")),
            format: nil
        ) as? [String: Any]
        return SignedTargetIdentity(
            kind: kind,
            bundleIdentifier: info?["CFBundleIdentifier"] as? String ?? "",
            teamIdentifier: "",
            applicationIdentifier: "",
            profileUUID: "",
            profileExpirationDate: .distantPast,
            signerSerialNumber: "",
            signerCertificateSHA256: "",
            status: status
        )
    }

    private func status(for failure: IdentityReadFailure) -> IdentityReadStatus {
        switch failure {
        case .signerMissing: return .unreadable
        case .inconsistentArchitectures: return .inconsistentArchitectures
        case .signerNotAuthorizedByProfile: return .signerNotAuthorizedByProfile
        case .invalidIPA, .incompleteIdentity, .targetSignerMismatch: return .unreadable
        }
    }

    private func requiredString(_ key: String, in info: [String: Any]?) throws -> String {
        guard let value = info?[key] as? String, value.isEmpty == false else {
            throw IdentityReadFailure.signerMissing
        }
        return value
    }
}
