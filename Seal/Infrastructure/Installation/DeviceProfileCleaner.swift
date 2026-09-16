//
//  DeviceProfileCleaner.swift
//  Seal
//
//  清理设备端旧描述文件，避免免费账号 7 天续签 / 反复重签导致 profile 无限累积。
//  两个触发点：
//    1. 安装成功后 —— 保留本次装进设备的那一组（主 App + 各扩展）；
//    2. 空闲维护 —— 按记录里「当前在用的是哪一份」回收历史堆积。
//  底层能力复用 Minimuxer 已有的 misagent copy_all / remove，Rust 零新增。
//
//  ⚠️ 删除方向必须是保守的：删错一份会让对应 App **立刻无法启动**（iOS 启动时校验
//  profile 是否还在设备上）。所以只处理「调用方明确给出保留 UUID」的 Bundle ID，
//  key 之外的一律不碰。
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

/// 自替换结算后的显式清理请求：锚定到具体事务与刚确认的安装身份。
struct ProfileCleanupRequest: Sendable, Equatable {
    let transactionID: UUID
    let bundleIdentifier: String
    let keepingProfileUUID: String
    let installedIdentityReadAt: Date
}

/// 结算路径的清理边界，便于用桩替换真实设备清理。
protocol SelfReplacementProfileCleaning: Sendable {
    func removeStaleProfiles(_ request: ProfileCleanupRequest) async -> ProfileCleanupSummary
}

/// 维护期的批量清理边界，便于用桩替换真实设备清理。
///
/// `keepingByBundleID` 的 key 是「Seal 管理的 Bundle ID」，value 是「该 Bundle ID 当前
/// 正在使用、必须保留的 profile UUID」。**key 集合之外的一律不碰** —— 设备上还有
/// MDM 配置描述文件、企业证书签的 App、其它工具装的 App，它们不在 Seal 的记录里，
/// 误删会让那些 App 直接无法启动。
protocol StaleProfileSweeping: Sendable {
    func sweepStaleProfiles(keepingByBundleID: [String: String]) async -> ProfileCleanupSummary
}

struct DeviceProfileCleaner: Sendable {
    /// 清理前重读运行身份的入口；缺失时一律跳过，绝不在身份不明时删除 profile。
    private let readRunningIdentity: (@Sendable () throws -> InstalledIdentity)?

    init(readRunningIdentity: (@Sendable () throws -> InstalledIdentity)? = nil) {
        self.readRunningIdentity = readRunningIdentity
    }

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
        return await removeStaleProfiles(
            keepingByBundleID: [bundleIdentifier: keepingProfileUUID]
        )
    }

    /// 按 Bundle ID 批量清理。每个 Bundle ID 只保留 map 里指定的那一份 profile，
    /// 其余同 Bundle ID 的设备端 profile 全部删除。
    ///
    /// 空 map 或整份 map 都无效时**什么都不做**：没有明确「保留哪一份」就不删，
    /// 因为删掉正在用的那一份会让已安装的 App 立刻无法启动（iOS 启动时会校验 profile）。
    @discardableResult
    static func removeStaleProfiles(
        keepingByBundleID: [String: String]
    ) async -> ProfileCleanupSummary {
        var normalized: [String: String] = [:]
        for (bundleID, uuid) in keepingByBundleID {
            let trimmedBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedUUID = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedBundleID.isEmpty == false, trimmedUUID.isEmpty == false else { continue }
            normalized[trimmedBundleID.lowercased()] = trimmedUUID.lowercased()
        }
        guard normalized.isEmpty == false else {
            return ProfileCleanupSummary(stage: "skipped-no-managed-bundle-ids")
        }
        return await removeProfiles(keepingByBundleID: normalized)
    }

    private static func removeProfiles(
        keepingByBundleID: [String: String]
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
            guard handledUUIDs.insert(profileUUID.lowercased()).inserted else { continue }
            summary.scanned += 1
            // 只有 Seal 管理的 Bundle ID 才参与判定；其余一律不碰。
            guard let keepingUUID = keepingByBundleID[profileBundleID.lowercased()] else {
                continue
            }
            summary.matched += 1
            if profileUUID.lowercased() == keepingUUID {
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

extension DeviceProfileCleaner: StaleProfileSweeping {
    func sweepStaleProfiles(keepingByBundleID: [String: String]) async -> ProfileCleanupSummary {
        await Self.removeStaleProfiles(keepingByBundleID: keepingByBundleID)
    }
}

extension DeviceProfileCleaner: SelfReplacementProfileCleaning {
    /// 结算后的精准清理：清理前重读当前运行身份，只有主程序 profile 仍等于
    /// 结算时确认的 `keepingProfileUUID` 才删除旧 profile；身份已变化或不可读
    /// 时整批放弃，绝不误删正在使用的 profile。清理失败只进摘要，不回滚已确认身份。
    func removeStaleProfiles(_ request: ProfileCleanupRequest) async -> ProfileCleanupSummary {
        guard let readRunningIdentity else {
            return ProfileCleanupSummary(stage: "skipped-identity-unavailable")
        }
        let identity: InstalledIdentity
        do {
            identity = try readRunningIdentity()
        } catch {
            var summary = ProfileCleanupSummary(stage: "skipped-identity-unavailable")
            summary.firstError = String(describing: error)
            return summary
        }
        guard identity.isComplete else {
            return ProfileCleanupSummary(stage: "skipped-identity-unavailable")
        }
        guard let mainProfileUUID = identity.mainTarget?.profileUUID,
              mainProfileUUID.caseInsensitiveCompare(request.keepingProfileUUID) == .orderedSame else {
            return ProfileCleanupSummary(stage: "skipped-identity-changed")
        }
        return await Self.removeStaleProfiles(
            for: request.bundleIdentifier,
            keeping: request.keepingProfileUUID
        )
    }
}
