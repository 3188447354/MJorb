import Foundation
import CodeSignKit

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

    init(inspectExecutable: @escaping Inspector = Self.inspectWithCodeSignKit) {
        self.inspectExecutable = inspectExecutable
    }

    /// 读取可执行文件的**真实签名身份** —— 照抄上游 SideStore 的做法 ✓
    ///
    /// ## 为什么换掉 rork-sign（2026-09-19，用户死命令「一个代码不漏地抄」✓）
    ///
    /// 上游 `SideStore/Core/Certificates/CertificateManager.swift:313-341`
    /// 的 `readBinaryCertificate(at:)` 是：
    /// ```swift
    ///     guard let parser = try? <上游用 MachOParser 解析可执行文件> else { return nil }
    /// let certChain = parser.x509Certificates()
    /// for (index, x509Cert) in certChain.enumerated() {
    ///     guard let derData = x509Cert.data else { continue }
    ///     let subjectDN = parseCertificate(derData: derData).subject
    ///     let isFilteredOut = subjectDN.contains("Root")
    ///                      || subjectDN.contains("Authority")
    ///                      || subjectDN.contains("Relations")
    ///     ...
    /// }
    /// ```
    /// **⇒ `MachOParser` 用 mmap 读** ✓（`MachOParser.swift:154,157` 的 `.mappedIfSafe` ✓），
    /// 而 rork-sign 的 `checkMachOCodeSignatures` 是整块读 ✗ —— 换掉它同时省内存 ✓。
    ///
    /// ## 语义（与原来一致，刻意保留的两条放宽 ✓）
    ///
    /// - **只把「能读出签名证书 serial」作为识别依据** ✓ —— 第三方工具（Sideloadly 的
    ///   bundle mangle、爱思的非标准结构）会让严格的全量 CodeDirectory 哈希校验失败 ✗，
    ///   但 CMS 密码学校验与签名证书仍可解析 ✓。若这里仍要求哈希有效，Seal 就永远读不出
    ///   第三方引导后的身份 ⇒ 触发 `SEAL-CERT-232` **中断轮换** ✗。
    /// - `cmsValid` / `codeDirectoryValid` 因此**只用于记录** ✓，不参与「识别成功」判定 ✓。
    private static func inspectWithCodeSignKit(_ executableURL: URL) throws -> ExecutableSignerEvidence {
        // ① 解析 Mach-O（上游 `MachOParser` ⇒ **mmap 读** ✓，不整块载入内存 ✓）
        guard let parser = try? MachOParser(url: executableURL) else {
            throw IdentityReadFailure.signerMissing
        }

        // ② 取证书链，并**照抄上游的过滤**：丢掉 Root / Intermediate CA ✓
        //    （上游判据：subject 里含 "Root" / "Authority" / "Relations" ✓）
        let chain = parser.x509Certificates()
        let leafCertificates = chain.filter { certificate in
            let subject = certificate.subjectSummary
            return !(subject.contains("Root")
                     || subject.contains("Authority")
                     || subject.contains("Relations"))
        }
        // 过滤后为空 ⇒ 退回整条链（第三方工具可能把 subject 写得不规范 ✗，
        // 那种情况下**宁可放宽也不误判「读不出身份」** ✓ —— 与原来的放宽语义一致 ✓）
        let candidates = leafCertificates.isEmpty ? chain : leafCertificates

        let normalizedSerials = candidates
            .map { SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumberHex) }
            .filter { $0.isEmpty == false }
        guard let first = normalizedSerials.first else {
            throw IdentityReadFailure.signerMissing
        }
        // ③ 各张证书（含多架构）的 serial 必须一致 —— 保留原来的防篡改检查 ✓
        guard normalizedSerials.allSatisfy({ $0 == first }) else {
            throw IdentityReadFailure.inconsistentArchitectures
        }

        // ④ CMS / 哈希状态：用上游的 `SignatureVerifier` ✓（照抄上游 ✓）
        //    ⚠️ 它内部是 `Data(contentsOf:)` 整块读 ✗（`SignatureVerifier.swift:62` ✓）——
        //    但这条路径只在**读身份**时走一次 ✓，不在签名热路径上 ✓；
        //    而且失败与否**不影响识别结果** ✓（见上面「刻意保留的两条放宽」✓）。
        let verification = SignatureVerifier.verify(url: executableURL, deep: false)
        return ExecutableSignerEvidence(
            serialNumber: first,
            cmsValid: verification.isValid,
            codeDirectoryValid: verification.isValid
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
