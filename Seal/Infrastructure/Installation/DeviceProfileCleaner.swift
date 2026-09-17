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
    /// dump 阶段实际尝试了几次（含首次）。> 1 说明前几次撞上了设备不可达。
    var dumpAttempts = 1

    var logMessage: String {
        var text = "描述文件清理：扫描 \(scanned)，匹配 \(matched)，删除 \(removed)"
        if removeFailed > 0 { text += "，删除失败 \(removeFailed)" }
        if stage != "done" { text += "，中断于 \(stage)" }
        if dumpAttempts > 1 { text += "，dump 尝试 \(dumpAttempts) 次" }
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

    /// dump 阶段的最大尝试次数（含首次）与重试间隔。
    ///
    /// 最坏耗时 ≈ 3 × 15 秒（每次 dump 内部自己的 `deviceFetchTimeoutMs` 轮询）+ 2 × 4 秒 ≈ 53 秒，
    /// 但整段都在后台任务里，不阻塞任何前台操作 —— 而 profile 堆积是免费账号下唯一会
    /// 持续累积、且会误导后续校验的问题，值得多花这点时间。
    private static let dumpAttemptLimit = 3
    private static let dumpRetryDelayNanoseconds: UInt64 = 4_000_000_000

    /// dump 设备端 profile，带**有界重试**。
    ///
    /// `Provision.dumpProfiles` 内部走 `Device.getFirstDevice()`，它会轮询
    /// `MuxerConstants.deviceFetchTimeoutMs`（15 秒）后抛 `NoDevice`。而两个触发点的时机
    /// 都**不保证设备已经连上**：
    ///   - 安装后清理紧随安装，RSD 连接可能正在重建；
    ///   - 维护期清理在 App 启动时，LocalDevVPN 隧道可能还没起来。
    ///
    /// 真机证据（2026-09-16 16:59:28）：`扫描 0，匹配 0，删除 0，中断于 dump，首个错误：NoDevice`
    /// —— 15 秒正好是 `deviceFetchTimeoutMs`，说明**一次都没重试**就整轮放弃了。
    /// 而同一账号的历史日志里清理是有成功记录的（`删除 1` / `删除 3`），所以问题不是
    /// 「清理不可用」，而是「撞上瞬时不可达就白丢一次机会」—— 下一次机会要等到下次安装
    /// 或下次启动，而 profile 在此期间继续累积。
    ///
    /// 每次重试前 `Provision.resetProvider()`：provider 可能缓存着一条已经断开的 RSD 连接，
    /// 不重置的话重试还是走同一条死路。
    private static func dumpProfiles(docsPath: String) async throws -> (path: String, attempts: Int) {
        for attempt in 1...dumpAttemptLimit {
            if attempt > 1 {
                // 先重置再等：重置拆掉缓存的死连接，等待让 RSD / 隧道有时间恢复。
                Provision.resetProvider()
                try? await Task.sleep(nanoseconds: dumpRetryDelayNanoseconds)
            }
            do {
                return (try Provision.dumpProfiles(docsPath: docsPath), attempt)
            } catch {
                if attempt == dumpAttemptLimit { throw error }
            }
        }
        // 循环内必然 return 或 throw；这行只为让编译器满意。
        throw MinimuxerError.NoDevice
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

        let dump: (path: String, attempts: Int)
        do {
            dump = try await dumpProfiles(docsPath: workingDir.path)
        } catch {
            summary.stage = "dump"
            summary.firstError = String(describing: error)
            return summary
        }
        summary.dumpAttempts = dump.attempts

        let dumpURL = URL(fileURLWithPath: dump.path)
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
