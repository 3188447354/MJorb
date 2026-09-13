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
                guard profileBundleID.caseInsensitiveCompare(bundleIdentifier) == .orderedSame else {
                    continue
                }
                guard profileUUID.caseInsensitiveCompare(keepingProfileUUID) != .orderedSame else {
                    continue
                }
                try? Provision.removeProvisioningProfile(id: profileUUID)
            }
        } catch {
            // 枚举 / 删除失败不影响安装结果。
        }
    }
}