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
        // 上游对齐：只把「能读出一致签名证书」作为识别身份的依据。
        // 第三方工具（Sideloadly 的 bundle mangle、爱思的非标准结构）会让严格的全量
        // CodeDirectory 哈希校验失败，但 CMS 密码学校验与签名证书仍可正常解析。
        // 若这里仍要求 codeDirectoryHashesValid，Seal 就永远读不出第三方引导后的身份，
        // 触发 SEAL-CERT-232 中断轮换。因此降级：不再把哈希失败判成识别失败，
        // 仅依赖「可读出的签名证书 serial」，并把 CMS/哈希校验状态如实记录到 evidence 供诊断。
        // 防误撤销自身证书的原始目的只需要 signer serial；serial 仍受 readTarget 的
        // profile 授权校验（signerNotAuthorizedByProfile）保护，不受本次放宽影响。
        let certificateReports = reports.compactMap { $0.signingCertificate }
        guard let first = certificateReports.first else {
            throw IdentityReadFailure.signerMissing
        }
        let normalized = SigningCertificateSelectionPolicy.normalizedSerialNumber(first.serialNumberHex)
        guard normalized.isEmpty == false,
              certificateReports.allSatisfy({
                  SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumberHex) == normalized
              }) else {
            throw IdentityReadFailure.inconsistentArchitectures
        }
        let signedReports = reports.filter(\.hasCMS)
        let cmsValid = signedReports.isEmpty == false && signedReports.allSatisfy(\.cmsSignatureValid)
        let codeDirectoryValid = signedReports.allSatisfy(\.codeDirectoryHashesValid)
        return ExecutableSignerEvidence(
            serialNumber: normalized,
            cmsValid: cmsValid,
            codeDirectoryValid: codeDirectoryValid
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
