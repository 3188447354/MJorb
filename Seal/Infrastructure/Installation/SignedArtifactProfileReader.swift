//
//  SignedArtifactProfileReader.swift
//  Seal
//
//  从「签名后成品 IPA」回读 embedded.mobileprovision，作为「安装成功后清理设备端
//  旧描述文件时保留刚装 profile」的依据。
//
//  覆盖**全部**会被 iOS 安装为独立 profile 的位置（主 App 与各扩展）：一次安装会为
//  每个扩展各装一份 profile，只按主 Bundle ID 清理会让扩展的旧 profile 在设备上
//  无限累积（2026-09-16 真机：LiveContainer 的 ShareExtension 一天内堆了 6 份，
//  Seal 自己累积到 17 份）。
//

import Foundation
import ZIPFoundation

enum SignedArtifactProfileReader {
    /// 「Payload / <App>.app / embedded.mobileprovision」的段数，用于校验路径形状。
    private static let mainProvisionSegmentCount = 3

    /// 签名产物内的一份描述文件：Bundle ID 取自 profile 自身的 `application-identifier`
    /// （已剥掉 TeamIdentifier 前缀），而不是从路径推断 —— 路径名与真实 Bundle ID 不一定一致。
    struct EmbeddedProfile: Sendable, Equatable {
        let bundleIdentifier: String
        let uuid: String
    }

    /// 枚举签名产物内所有会被安装的 embedded.mobileprovision（主 App + 扩展），按 UUID 去重。
    ///
    /// 返回值只应被调用方当作「保留集合」使用：解析不出 UUID / Bundle ID 的条目会被跳过，
    /// 缺项意味着那一条不会被清理，而不会导致误删（方向是安全的）。
    static func embeddedProfiles(in ipaData: Data) -> [EmbeddedProfile] {
        guard let archive = try? Archive(data: ipaData, accessMode: .read) else { return [] }

        var profiles: [EmbeddedProfile] = []
        var seenUUIDs = Set<String>()
        let reader = ProvisioningProfileReader()

        for entry in archive where isInstalledAppProvision(entry.path) {
            var profileData = Data()
            do {
                _ = try archive.extract(entry) { chunk in
                    profileData.append(chunk)
                }
            } catch {
                continue
            }
            guard profileData.isEmpty == false,
                  let details = try? reader.details(from: profileData),
                  let uuid = details.uuid,
                  let bundleIdentifier = details.bundleIdentifier,
                  bundleIdentifier.isEmpty == false else {
                continue
            }
            // 同一 profile 可能被重复嵌入（主 App 与扩展共用一份），按 UUID 去重。
            guard seenUUIDs.insert(uuid.lowercased()).inserted else { continue }
            profiles.append(EmbeddedProfile(bundleIdentifier: bundleIdentifier, uuid: uuid))
        }
        return profiles
    }

    /// iOS 实际会安装为独立 profile 的位置：Payload 下任意**应用包**根目录的
    /// embedded.mobileprovision。
    ///
    /// 容器后缀必须同时认 `.app`（主 App、AppClips、Watch）与 `.appex`
    /// （PlugIns 下的扩展 —— 本仓 `SigningWorkspace` / `AppBundleSigningIdentityReader`
    /// / `ApplePortalSigningService` 都用 `pathExtension == "appex"` 识别扩展）。
    /// **只认 `.app` 会静默漏掉全部扩展**，等于扩展清理根本没生效。
    ///
    /// 刻意排除 `Frameworks/*.framework/embedded.mobileprovision`：framework 的 profile
    /// 不会被 installd 装成设备 profile，把它算进保留集合会让真正的旧 profile 被误判为在用。
    private static func isInstalledAppProvision(_ path: String) -> Bool {
        let segments = path.split(separator: "/")
        guard segments.count >= mainProvisionSegmentCount,
              segments[0] == "Payload",
              segments[segments.count - 1] == "embedded.mobileprovision" else { return false }
        let container = segments[segments.count - 2]
        return container.hasSuffix(".app") || container.hasSuffix(".appex")
    }
}
