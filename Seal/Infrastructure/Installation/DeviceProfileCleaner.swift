//
//  DeviceProfileCleaner.swift
//  Seal
//
//  安装成功后清理设备端「同一 Bundle ID」下的旧描述文件（保留刚装的那份），
//  避免免费账号 7 天续签 / 反复重签导致设备端 provisioning profile 无限累积。
//  底层能力复用 Minimuxer 已有的 misagent copy_all / remove，Rust 零新增。
//

import Foundation
@preconcurrency import Minimuxer

struct DeviceProfileCleaner: Sendable {
    /// 删除设备端与 `bundleIdentifier` 相同、但 UUID ≠ `keepingProfileUUID` 的旧描述文件。
    ///
    /// 这是「最佳努力」清理：任何一步失败都静默返回，绝不阻断主安装 / 签名结果。
    /// 没有刚装 profile 的 UUID 就无法安全区分「旧」与「刚装」，此时直接放弃，避免误删。
    static func removeStaleProfiles(
        for bundleIdentifier: String,
        keeping keepingProfileUUID: String?
    ) async {
        guard let keepingProfileUUID,
              keepingProfileUUID.isEmpty == false,
              bundleIdentifier.isEmpty == false else {
            return
        }
        await removeProfiles(matching: [bundleIdentifier], keeping: keepingProfileUUID)
    }

    /// 自更新「安装前」调用：新 profile 尚未落到设备，凡匹配 bundle ID 的都是旧文件，全部删除。
    /// 即使随后安装失败，启动校验只看包内 embedded.mobileprovision、与设备 profile 列表无关，
    /// 旧应用仍可打开，因此此处删除是安全的。
    static func removeAllProfiles(for bundleIdentifiers: [String]) async {
        let ids = bundleIdentifiers.filter { $0.isEmpty == false }
        guard ids.isEmpty == false else { return }
        await removeProfiles(matching: ids, keeping: nil)
    }

    private static func removeProfiles(
        matching bundleIdentifiers: [String],
        keeping keepingProfileUUID: String?
    ) async {
        let reader = ProvisioningProfileReader()
        let fileManager = FileManager.default
        let workingDir = fileManager.temporaryDirectory
            .appendingPathComponent("seal-profile-clean-\(UUID().uuidString)", isDirectory: true)

        defer { try? fileManager.removeItem(at: workingDir) }

        do {
            let dumpDir = try Provision.dumpProfiles(docsPath: workingDir.path)
            let dumpURL = URL(fileURLWithPath: dumpDir)
            let profileURLs = (try? fileManager.contentsOfDirectory(
                at: dumpURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            for fileURL in profileURLs {
                guard fileURL.pathExtension.lowercased() == "mobileprovision",
                      let data = try? Data(contentsOf: fileURL),
                      let details = try? reader.details(from: data),
                      let profileUUID = details.uuid,
                      let profileBundleID = details.bundleIdentifier else {
                    continue
                }
                guard bundleIdentifiers.contains(where: {
                    profileBundleID.caseInsensitiveCompare($0) == .orderedSame
                }) else {
                    continue
                }
                if let keepingProfileUUID,
                   profileUUID.caseInsensitiveCompare(keepingProfileUUID) == .orderedSame {
                    continue
                }
                try? Provision.removeProvisioningProfile(id: profileUUID)
            }
        } catch {
            // 枚举 / 删除失败不影响安装结果。
        }
    }
}