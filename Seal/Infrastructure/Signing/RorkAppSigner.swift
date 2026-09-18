import Foundation
import RorkSign

/// 基于 rork-sign（纯 Swift zsign 兼容签名引擎）的 App 签名器。
///
/// 替代 ALTSigner/ldid：
/// - 纯 Swift 流式处理，大 IPA 不会触发 ldid.cpp(538) 内存崩溃；
/// - 自己实现 CMS/PKCS#7 签名，格式与 zsign/codesign 对齐；
/// - inside-out 一次签名主 app、扩展、Framework，并自动嵌入描述文件、生成 CodeResources。
///
/// 本类型只依赖 Foundation + RorkSign（不依赖 AltSign），入参全部是 Sendable 的
/// String/Data，可安全地在后台线程/Task.detached 中执行 CPU 密集型签名。
///
/// P12 解析由调用方（ApplePortalSigningService）用 AltSign 的 ALTCertificate 完成，
/// 因为 AltSign 用 OpenSSL 生成/解析 P12，与 iOS 原生 SecPKCS12Import 和 rork-sign
/// 自带 PKCS12 解析器均不兼容。这里只接收已解析好的 PEM 证书和私钥。
enum RorkAppSigner {

    /// 一个待嵌入的描述文件：bundleID 为改写后的 ID，data 为描述文件原始字节。
    struct ProfileMaterial: Sendable {
        let bundleID: String
        let data: Data
    }

    enum SignError: LocalizedError {
        case missingCertificate
        case missingPrivateKey
        case missingMainProfile(String)
        case identityImportFailed(String)
        case signFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingCertificate:
                return "证书数据缺失，请重新登录 Apple ID 后重试"
            case .missingPrivateKey:
                return "私钥数据缺失，请重新登录 Apple ID 后重试"
            case .missingMainProfile(let bundleID):
                return "主应用描述文件缺失：\(bundleID)"
            case .identityImportFailed(let detail):
                return "证书导入失败：\(detail)"
            case .signFailed(let detail):
                return "签名失败：\(detail)"
            }
        }
    }

    /// 用 rork-sign 原地签名整个 .app bundle。
    ///
    /// 调用前 `SigningWorkspace.prepare` 已完成：解压、改 BundleID、strip arm64e、
    /// 删除旧 _CodeSignature。本方法只负责正式的 CMS 签名（不做 ad-hoc 预处理，
    /// 与 ldid / SideStore 一致，直接对原始 Mach-O 正式签名）。
    /// 可在后台线程执行。
    ///
    /// - Parameters:
    ///   - appURL: .app bundle 路径
    ///   - certificateData: PEM 或 DER 格式证书（由 AltSign ALTCertificate 从 P12 解析）
    ///   - privateKeyData: PEM 或 DER 格式私钥（由 AltSign ALTCertificate 从 P12 解析）
    ///   - mainBundleID: 主应用改写后的 Bundle ID（prepared.mappedMainBundleID）
    ///   - profiles: 全部描述文件（主应用 + 扩展），bundleID 均为改写后的 ID
    @discardableResult
    static func signAppBundle(
        at appURL: URL,
        certificateData: Data,
        privateKeyData: Data,
        mainBundleID: String,
        profiles: [ProfileMaterial],
        appGroupIdentifiers: [String] = []
    ) throws -> SigningCacheStats {
        guard certificateData.isEmpty == false else {
            throw SignError.missingCertificate
        }
        guard privateKeyData.isEmpty == false else {
            throw SignError.missingPrivateKey
        }

        // 主描述文件：优先精确匹配主 Bundle ID，兜底取第一个
        guard let mainProfile = profiles.first(where: {
            $0.bundleID.caseInsensitiveCompare(mainBundleID) == .orderedSame
        }) ?? profiles.first else {
            throw SignError.missingMainProfile(mainBundleID)
        }

        // 扩展描述文件：按"改写后的 Bundle ID -> 描述文件数据"建索引
        var extensionProfiles: [String: Data] = [:]
        for profile in profiles {
            if profile.bundleID.caseInsensitiveCompare(mainBundleID) == .orderedSame {
                continue
            }
            extensionProfiles[profile.bundleID] = profile.data
        }

        // rork-sign 接受 PEM 或 DER 格式的证书和私钥，AltSign 解析出的是 PEM
        let identity: SigningIdentity
        do {
            identity = try SigningIdentity(
                certificateData: certificateData,
                privateKeyData: privateKeyData
            )
        } catch {
            throw SignError.identityImportFailed(error.localizedDescription)
        }

        // 主 Bundle ID 已在 prepare 阶段改写，这里传同一个 ID，rork-sign rebase 后保持不变
        let options = AppSigningOptions(
            bundleIdentifier: mainBundleID,
            rootProvisioningProfile: mainProfile.data,
            provisioningProfilesByBundleIdentifier: extensionProfiles,
            appGroupIdentifiers: appGroupIdentifiers,
            embedProvisioningProfiles: true,
            // 对齐 ldid / zsign 默认：SHA-1 主 CodeDirectory + SHA-256 备用 CodeDirectory，
            // 兼容 iOS 16.0-27 全版本（单 SHA-256 CD 在部分老系统上校验更易失败）。
            codeDirectoryHashingMode: .compatible,
            // ⚠️ 签名缓存（2026-09-18）：见 `SigningCacheStore` 的注释。
            // 取不到就传 nil ⇒ 退化成原来的「每次全量重签」，**不会失败**。
            signingCache: SigningCacheStore.preparedOptions()
        )

        do {
            let result = try RorkSigner.signBundle(
                at: appURL,
                identity: identity,
                options: options
            )
            return SigningCacheStats(
                signed: result.signedCode.count,
                cached: result.cachedCode.count
            )
        } catch {
            throw SignError.signFailed(error.localizedDescription)
        }
    }
}

/// 一次重签里「新算的」与「缓存命中的」Mach-O 个数（2026-09-18）。
///
/// 返回给调用方打日志用 —— **本类型刻意不引入 logger**（`RorkAppSigner` 至今没有 logger，
/// 为了一行日志给它塞一个 `SealLogStore?` 是过度设计）。
struct SigningCacheStats: Sendable {
    let signed: Int
    let cached: Int
}

/// 签名缓存的落点与淘汰（2026-09-18）。
///
/// 引擎的 `SigningCacheOptions` 按**内容寻址**缓存「已签名的 Mach-O」：
/// key 覆盖 **证书哈希 + entitlements 哈希 + Mach-O 内容 + CD 哈希模式**
/// （`BundleSignatureCache.swift:51-67 / 134-180`），**不含描述文件字节**。
///
/// ⇒ **续签同一个 App 时会命中**：证书不变（免费账号证书约 1 年，7 天过期的只是描述文件）、
/// entitlements 不变（刷新出来的描述文件内容相同）、包内容不变 ⇒ key 不变
/// ⇒ 那 30 多个 Mach-O 的重签可以全部跳过。**这正是主场景（7 天续签）。**
///
/// ⚠️ **引擎没有淘汰机制**（`prune` / `trim` / `clear` / `sizeLimit` 在缓存实现里 0 命中），
/// 而缓存里存的是**已签名 Mach-O 的副本**（大包量级不小）⇒ 上限必须 Seal 自己管。
///
/// ⚠️ 放 `Library/Caches` 而**不是** `ApplicationSupport`：缓存**可再生** ⇒
/// 不该进 iCloud 备份；被系统清掉也只是下次变慢，**不会出错**（内容寻址 ⇒ 错命中不可能）。
///
/// ⚠️ **本类型任何失败都只返回 nil / 静默放过** —— 缓存是「有更好、没有也能签」的东西，
/// **绝不允许它把签名搞失败**。（引擎的 `store` 本身就 `throws`-free，写失败不会冒泡 ✓。）
enum SigningCacheStore {
    /// 上限：超过就按**最久未使用**删到 70%。宁可清掉，也不让它无界增长。
    static let byteLimit = 400 * 1024 * 1024

    static func directoryURL(fileManager: FileManager = .default) -> URL? {
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return caches
            .appending(
                path: AppConfiguration.Paths.applicationSupportSubdirectory,
                directoryHint: .isDirectory
            )
            .appending(path: "SigningCache", directoryHint: .isDirectory)
    }

    static func preparedOptions(fileManager: FileManager = .default) -> SigningCacheOptions? {
        guard let directory = directoryURL(fileManager: fileManager) else { return nil }
        guard (try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )) != nil else {
            return nil
        }
        pruneIfNeeded(in: directory, fileManager: fileManager)
        return SigningCacheOptions(directoryURL: directory)
    }

    /// 条目文件名是 `<key digest>.json`（`BundleSignatureCache.swift:115`）⇒ 按 mtime 淘汰即可。
    static func pruneIfNeeded(in directory: URL, fileManager: FileManager = .default) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var files: [(url: URL, size: Int, modified: Date)] = []
        var total = 0
        for entry in entries {
            guard let values = try? entry.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            ), let size = values.fileSize else { continue }
            files.append((entry, size, values.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > byteLimit else { return }

        let target = byteLimit * 7 / 10
        for file in files.sorted(by: { $0.modified < $1.modified }) {
            guard total > target else { break }
            if (try? fileManager.removeItem(at: file.url)) != nil {
                total -= file.size
            }
        }
    }
}
