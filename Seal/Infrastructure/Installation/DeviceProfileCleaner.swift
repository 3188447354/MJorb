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

/// 一次清理的执行摘要。清理是「最佳努力」、永不抛出，
/// 摘要是唯一排障依据（历史上静默失败导致 109 条旧 profile 一条没删掉还毫无线索）。
struct ProfileCleanupSummary: Sendable, Equatable {
    var scanned = 0
    var matched = 0
    var removed = 0
    var removeFailed = 0
    var stage: String = "done"
    var firstError: String?

    var logMessage: String {
        var text = "描述文件清理：扫描 \(scanned)，匹配 \(matched)，删除 \(removed)"
        if removeFailed > 0 { text += "，删除失败 \(removeFailed)" }
        if stage != "done" { text += "，中断于 \(stage)" }
        if let firstError { text += "，首个错误：\(firstError)" }
        return text
    }
}

struct DeviceProfileCleaner: Sendable {
    /// 删除设备端与 `bundleIdentifier` 相同、但 UUID ≠ `keepingProfileUUID` 的旧描述文件。
    ///
    /// 这是「最佳努力」清理：任何一步失败都不阻断主安装 / 签名结果，失败细节进返回的摘要。
    /// 没有刚装 profile 的 UUID 就无法安全区分「旧」与「刚装」，此时直接放弃，避免误删。
    @discardableResult
    static func removeStaleProfiles(
        for bundleIdentifier: String,
        keeping keepingProfileUUID: String?
    ) async -> ProfileCleanupSummary {
        guard let keepingProfileUUID,
              keepingProfileUUID.isEmpty == false,
              bundleIdentifier.isEmpty == false else {
            return ProfileCleanupSummary(stage: "skipped-no-keeping-uuid")
        }
        return await removeProfiles(matching: [bundleIdentifier], keeping: keepingProfileUUID)
    }

    /// 自更新「安装前」调用：新 profile 尚未落到设备，凡匹配 bundle ID 的都是旧文件，全部删除。
    /// 即使随后安装失败，启动校验只看包内 embedded.mobileprovision、与设备 profile 列表无关，
    /// 旧应用仍可打开，因此此处删除是安全的。
    @discardableResult
    static func removeAllProfiles(for bundleIdentifiers: [String]) async -> ProfileCleanupSummary {
        let ids = bundleIdentifiers.filter { $0.isEmpty == false }
        guard ids.isEmpty == false else {
            return ProfileCleanupSummary(stage: "skipped-empty-ids")
        }
        return await removeProfiles(matching: ids, keeping: nil)
    }

    private static func removeProfiles(
        matching bundleIdentifiers: [String],
        keeping keepingProfileUUID: String?
    ) async -> ProfileCleanupSummary {
        var summary = ProfileCleanupSummary()
        let reader = ProvisioningProfileReader()
        let fileManager = FileManager.default
        let workingDir = fileManager.temporaryDirectory
            .appendingPathComponent("seal-profile-clean-\(UUID().uuidString)", isDirectory: true)

        defer { try? fileManager.removeItem(at: workingDir) }

        let dumpDir: String
        do {
            dumpDir = try Provision.dumpProfiles(docsPath: workingDir.path)
        } catch {
            summary.stage = "dump"
            summary.firstError = String(describing: error)
            return summary
        }

        let dumpURL = URL(fileURLWithPath: dumpDir)
        let profileURLs = (try? fileManager.contentsOfDirectory(
            at: dumpURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var handledUUIDs = Set<String>()
        for fileURL in profileURLs {
            // 不按扩展名过滤：misagent 返回的是 CMS 签名包裹的二进制，
            // Rust 端解析不了会落成 unknown_N.plist；真正的识别靠 ProvisioningProfileReader 解 CMS。
            guard let data = try? Data(contentsOf: fileURL),
                  let details = try? reader.details(from: data),
                  let profileUUID = details.uuid,
                  let profileBundleID = details.bundleIdentifier else {
                if summary.firstError == nil {
                    summary.firstError = "parse失败: \(fileURL.lastPathComponent)"
                }
                continue
            }
            // LockDown 路径同一 profile 会落 raw + plist 两个文件，按 UUID 去重
            guard handledUUIDs.insert(profileUUID).inserted else { continue }
            summary.scanned += 1
            guard bundleIdentifiers.contains(where: {
                profileBundleID.caseInsensitiveCompare($0) == .orderedSame
            }) else {
                continue
            }
            summary.matched += 1
            if let keepingProfileUUID,
               profileUUID.caseInsensitiveCompare(keepingProfileUUID) == .orderedSame {
                continue
            }
            do {
                try Provision.removeProvisioningProfile(id: profileUUID)
                summary.removed += 1
            } catch {
                summary.removeFailed += 1
                if summary.firstError == nil {
                    summary.firstError = "remove失败: \(String(describing: error))"
                }
            }
        }
        return summary
    }
}
