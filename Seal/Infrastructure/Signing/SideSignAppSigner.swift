import Foundation
import SideSign

/// **用上游（SideStore）的签名器重签整个 .app bundle** —— 照抄 `SideSign` 的 `AppBundleSigner` ✓
///
/// ## 为什么要有这个文件（2026-09-19，用户死命令：「一个代码不漏地抄，签名器不一样你就换」）
///
/// Seal 原来用 `Vendor/rork-sign` ✗ —— 它在**手机上签大包**时内存峰值达到
/// **2.11 GB**（真机 `JetsamEvent`：`largestProcess = "Seal"`，`rpages 129697 × 16KB`），
/// 被 iOS **jetsam** 杀掉，并且连带杀掉后台的网易云 / LocalDevVPN ✗✗。
///
/// 而 **SideStore（同样跑在手机上）签大包没问题** ✓ —— 因为它用的是
/// **`SideSign` → `CodeSignKit`** ✓。上游的做法（逐行查证 ✓）：
///
/// ```swift
/// // CodeSignKit/MachOParser.swift:154,157
/// self.data = try Data(contentsOf: url, options: .mappedIfSafe)        // mmap 读（0 内存）
/// // CodeSignKit/MachOSigner.swift:301
/// var finalBinary = workingData.subdata(in: 0..<min(codeLimit, workingData.count))
///                                                                      // 复制出新 Data 再改（1×）
/// ```
///
/// **⇒ mmap 读 + 复制后改 ⇒ 全程只有 1 份** ✓（Seal 原来是「整块读 + 原地改 ⇒ COW 复制」= 2 份 ✗）
///
/// ## 本文件不重新实现任何签名逻辑 ✓
///
/// **直接调用上游的 `AppBundleSigner.signApp`** ✓ —— 它内部完成：
/// ① 匹配 profile ② 算 filtered entitlements ③ 写 `embedded.mobileprovision`
/// ④ 调 `CodeSigner.sign`（CodeSignKit ✓）自内向外签名 ✓
///
/// 本文件**只做一件事**：把 Seal 手里的数据翻译成上游要的三个类型 ✓
enum SideSignAppSigner {

    /// 一个待嵌入的描述文件（bundleID 为**改写后**的 ID ✓，与 `RorkAppSigner` 同形）。
    struct ProfileMaterial: Sendable {
        let bundleID: String
        let data: Data
    }

    enum SignError: LocalizedError {
        // ⚠️ 这 3 个 case 是**从 `RorkAppSigner.SignError` 迁过来的** ✓
        //（2026-09-19 删 rork-sign 时 ✓）—— 调用方 `ApplePortalSigningService`
        // 的报错文案与日志码都依赖它们 ✓，**文案一字不改** ✓。
        case missingCertificate
        case missingPrivateKey
        case invalidCertificate
        case missingMainProfile(String)
        case identityImportFailed(String)
        case signFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingCertificate:
                return "证书数据缺失，请重新登录 Apple ID 后重试"
            case .missingPrivateKey:
                return "私钥数据缺失，请重新登录 Apple ID 后重试"
            case .invalidCertificate:
                return "证书数据无法解析（PEM / DER 都试过了），请重新登录 Apple ID 后重试"
            case .missingMainProfile(let bundleID):
                return "主应用描述文件缺失：\(bundleID)"
            case .identityImportFailed(let detail):
                return "证书导入失败：\(detail)"
            case .signFailed(let detail):
                return "签名失败：\(detail)"
            }
        }
    }

    /// 用上游签名器原地重签整个 `.app` bundle ✓
    ///
    /// - Parameters:
    ///   - appURL: `.app` bundle 路径（`SigningWorkspace.prepare` 已完成解压 / 改 BundleID ✓）
    ///   - certificateData: 证书字节，**PEM 或 DER 都行** ✓
    ///     （上游 `X509Certificate(data:)` 内部会转 ✓；AltSign 给的是 PEM ✓）
    ///   - privateKeyData: 私钥字节（PEM 或 DER ✓，上游直接透传 ✓）
    ///   - teamID / teamName: 开发者团队 ✓
    ///   - isFreeTeam: 免费团队 ⇒ `TeamType.free` ✓；否则 `TeamType.individual` ✓
    ///     （⚠️ 上游的 `TeamType` 只有 `unknown` / `organization` / `individual` / `free` ✗，
    ///       **没有 `.paid`** ✓）
    ///   - profiles: 全部描述文件（主 App + 扩展 ✓，bundleID 均为改写后的 ID ✓）
    ///   - mainBundleID: 主 App 改写后的 Bundle ID（用于校验主 profile 存在 ✓）
    static func signAppBundle(
        at appURL: URL,
        certificateData: Data,
        privateKeyData: Data,
        teamID: String,
        teamName: String,
        isFreeTeam: Bool,
        mainBundleID: String,
        profiles: [ProfileMaterial]
    ) async throws {
        // ① 主描述文件必须存在 —— 上游在 `prepare` 里会抛 `missingProvisioningProfile`，
        //    这里提前给一个**可归因**的错误 ✓（否则报错会晚到且不好定位 ✗）。
        //    ⚠️ 判据必须是「**恰好命中主 Bundle ID**」✗ —— 不能写成
        //    `contains(主) || profiles.isEmpty == false`（那等于只要非空就通过 ✗）。
        guard profiles.contains(where: {
            $0.bundleID.caseInsensitiveCompare(mainBundleID) == .orderedSame
        }) else {
            throw SignError.missingMainProfile(mainBundleID)
        }

        // ② 证书：上游的 `X509Certificate(data:)` **同时接受 PEM 和 DER** ✓✓
        //    （`SideSign/Sources/Models/X509Certificate.swift:146`：
        //      不是 PEM 就包成 PEM ⇒ 再 `CertificateParser.extractDER` 解成 DER ✓）
        //
        //    ⚠️ **不要用 `X509Certificate(der:)`** ✗ —— 那个只吃 DER，
        //    而 AltSign 的 `ALTCertificate.data` 是 **PEM**
        //    （`ALTCertificate.swift:31` 有 `-----BEGIN CERTIFICATE-----` 前缀 ✓）
        //    ⇒ 用 `der:` 会**直接返回 nil** ✗。
        guard let certificate = X509Certificate(data: certificateData) else {
            throw SignError.invalidCertificate
        }

        // ③ 三个类型全部由 Seal 手里的数据构造 ✓
        //    ⚠️ **刻意用 `KeyStore(certificate:privateKey:)` 而不是 `KeyStore(p12Data:)`** ✗：
        //    Seal 的 p12 是 **AltSign 用 OpenSSL** 生成的，与上游自带的 `PKCS12Parser`
        //    兼容性未知 ✗；而证书 + 私钥是 Seal 本来就有的 ✓ ⇒ **绕过 p12 解析** ✓。
        let keyStore = KeyStore(certificate: certificate, privateKey: privateKeyData)
        let team = Team(
            identifier: teamID,
            name: teamName,
            type: isFreeTeam ? .free : .individual
        )
        let provisioningProfiles = try profiles.map { try ProvisioningProfile(data: $0.data) }

        // ④ 交给上游 —— **签名逻辑一行都不自己写** ✓
        do {
            try await AppBundleSigner(team: team, keyStore: keyStore)
                .signApp(at: appURL, provisioningProfiles: provisioningProfiles, progress: nil)
        } catch {
            throw SignError.signFailed(error.localizedDescription)
        }
    }
}

/// 一次重签里「新算的」与「缓存命中的」Mach-O 个数。
///
/// ⚠️ **从 `RorkAppSigner` 迁过来**（2026-09-19 删 rork-sign ✓）。
/// **上游 `SideSign` / `CodeSignKit` 没有签名缓存** ✗
///（rork-sign 的 `SigningCacheOptions` 是它独有的优化 ✓）⇒ 这里**恒为 `(0, 0)`** ✓。
///
/// 保留这个类型只是为了让调用方（`ApplePortalSigningService`）的日志与结构不用改 ✓ ——
/// **将来若上游加上缓存，直接填真值即可** ✓。
struct SigningCacheStats: Sendable {
    let signed: Int
    let cached: Int
}
