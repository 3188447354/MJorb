import Foundation
import UIKit

struct SelfAppMetadata: Sendable {
    let bundleURL: URL
    let bundleIdentifier: String
    let originalBundleIdentifier: String?
    let name: String
    let version: String
    let buildNumber: String
    let iconData: Data?
    let expirationDate: Date?
    let signingTeamIdentifier: String?
    let signingApplicationIdentifier: String?
    /// 运行中包内 `embedded.mobileprovision` 的身份。同版本续签会换掉 profile 但**版本号不变**，
    /// 因此 profile 身份是判断「续签是否真的生效」的唯一可观测证据（见 R07）。
    var provisioningProfileUUID: String? = nil
    var provisioningProfileName: String? = nil
    var provisioningProfileCreationDate: Date? = nil
    /// 运行包描述文件里授权的证书序列号列表。Seal 注册时必须从这里取真实的证书序列号，
    /// 而不是继承旧记录——爱思/其他工具签的 Seal，证书不是 Seal 创建的，
    /// 如果记录里存的是旧值或 nil，前置清理会误撤 Seal 在用的证书导致变砖。
    var certificateSerialNumbers: [String] = []

    @MainActor
    static func current(bundle: Bundle = .main) -> SelfAppMetadata? {
        guard let bundleIdentifier = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Seal"
        let version = (bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String) ?? "1.0"
        let buildNumber = (bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String) ?? "1"
        // 直接读取 .app 路径，不能依赖 Bundle 的资源查询缓存。自替换安装可能在当前
        // 进程尚未退出时原地更新 Seal.app；此时只有磁盘上的 embedded.mobileprovision
        // 能证明新包是否真的落盘。
        let profileURL = bundle.bundleURL.appending(path: "embedded.mobileprovision")
        // 用 details 而不是 summary：summary 不含 UUID/Name/CreationDate，
        // 而「同版本续签是否生效」只能靠 profile 身份判断。
        let profileDetails = (try? Data(contentsOf: profileURL, options: .mappedIfSafe))
            .flatMap { try? ProvisioningProfileReader().details(from: $0) }

        return SelfAppMetadata(
            bundleURL: bundle.bundleURL,
            bundleIdentifier: bundleIdentifier,
            originalBundleIdentifier: bundle.object(
                forInfoDictionaryKey: "SealOriginalBundleIdentifier"
            ) as? String,
            name: name,
            version: version,
            buildNumber: buildNumber,
            iconData: iconData(bundle: bundle),
            expirationDate: profileDetails?.expirationDate,
            signingTeamIdentifier: profileDetails?.teamIdentifier,
            signingApplicationIdentifier: profileDetails?.applicationIdentifier,
            provisioningProfileUUID: profileDetails?.uuid,
            provisioningProfileName: profileDetails?.name,
            provisioningProfileCreationDate: profileDetails?.creationDate,
            certificateSerialNumbers: profileDetails?.certificateSerialNumbers ?? []
        )
    }

    @MainActor
    private static func iconData(bundle: Bundle) -> Data? {
        let names = iconFileNames(bundle: bundle)
        for name in names.reversed() {
            if let data = resourceIconData(name: name, bundle: bundle) { return data }
            if let image = UIImage(named: name, in: bundle, compatibleWith: nil),
               let data = image.pngData() {
                return data
            }
        }

        for candidate in ["AppIcon", "SealIcon", "Icon", "iTunesArtwork", "iTunesArtwork@2x"] {
            if let data = resourceIconData(name: candidate, bundle: bundle) { return data }
            if let image = UIImage(named: candidate, in: bundle, compatibleWith: nil),
               let data = image.pngData() {
                return data
            }
        }
        return nil
    }

    private static func iconFileNames(bundle: Bundle) -> [String] {
        let info = bundle.infoDictionary ?? [:]
        var names: [String] = []
        if let icons = info["CFBundleIcons"] as? [String: Any],
           let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primaryIcon["CFBundleIconFiles"] as? [String] {
            names.append(contentsOf: files)
        }
        if let files = info["CFBundleIconFiles"] as? [String] {
            names.append(contentsOf: files)
        }
        return Array(NSOrderedSet(array: names)) as? [String] ?? names
    }

    private static func resourceIconData(name: String, bundle: Bundle) -> Data? {
        let url = URL(fileURLWithPath: name)
        let resourceName = url.deletingPathExtension().lastPathComponent
        let resourceExtension = url.pathExtension
        let extensions = resourceExtension.isEmpty ? ["png", ""] : [resourceExtension]
        for ext in extensions {
            let found = ext.isEmpty
                ? bundle.url(forResource: resourceName, withExtension: nil)
                : bundle.url(forResource: resourceName, withExtension: ext)
            if let found, let data = try? Data(contentsOf: found, options: .mappedIfSafe) {
                return data
            }
        }
        return nil
    }
}
