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

    // ── 旧 Team 变体（孤儿）回收的计数 ────────────────────────────────────────
    // 这四个数分开记，是为了让「一条都没删」能归因到具体原因：
    // 分不清「形态没匹配上」「设备上确实还装着」「核验查不通」就只能猜。
    /// 形态上像 Seal 生成的孤儿（`ProfileReclaimPolicy.isReclaimableOrphan`）的份数。
    ///
    /// 是**本地形态筛出来的总量**，不是「核验过的量」—— 中止时后面那些根本没问设备。
    var reclaimCandidates = 0
    /// 其中真正删掉的份数。
    var reclaimed = 0
    /// 因为「设备上确实装着对应 App」而**保留**的份数。
    ///
    /// 只在一种情况下出现：某个 Bundle ID 形态上像 Seal 生成的、**但不在保留集合里**，
    /// 而设备上确实装着 —— 主要是「App 还在设备上、却已从 Seal 列表里删掉」
    /// （或记录里没有可信的 profile UUID）。`> 0` 是**保护生效**，不是漏删；`= 0` 也正常。
    ///
    /// ⚠️ 「同一个 App 用两个 Team 各装一份」**不**走这条路径：两个 ID 都在 keep-map 里，
    /// 由保留集合内去重（路径 1）处理。别把这两个场景混起来。
    var reclaimKeptInstalled = 0
    /// 因为「查不出是否安装」而保守跳过的份数。
    ///
    /// **设计上只可能是 0 或 1**：核验抛错说明通道是全局性的不健康，
    /// 见 `ProfileReclaimPolicy.decision` —— 第一次 `unavailable` 就中止整轮，
    /// 不再拿剩下的候选去问一条已经不可信的通道。
    var reclaimUnverified = 0
    /// 回收被中止的原因（`nil` ⇒ 没中止）。中止后**不再删任何一份**。
    ///
    /// 单列字段而不是复用 `stage`：`stage` 表示「整个清理流水线断在哪一步」，
    /// 而回收中止**不影响路径 1**（保留集合内去重）的结果 ——
    /// 混在一起会让人以为整轮白跑，进而重复排查。
    var reclaimAborted: String?
    /// 候选 Bundle ID 的样本（最多 `reclaimSampleLimit` 个），进日志供人工核对。
    var reclaimSample: [String] = []

    /// 样本上限：日志行要能一眼看完，全量候选留给后续排查时再捞。
    static let reclaimSampleLimit = 6

    var logMessage: String {
        var text = "描述文件清理：扫描 \(scanned)，匹配 \(matched)，删除 \(removed)"
        if removeFailed > 0 { text += "，删除失败 \(removeFailed)" }
        if stage != "done" { text += "，中断于 \(stage)" }
        if dumpAttempts > 1 { text += "，dump 尝试 \(dumpAttempts) 次" }
        if let firstError { text += "，首个错误：\(firstError)" }
        if reclaimCandidates > 0 {
            text += "；旧 Team 变体：候选 \(reclaimCandidates)，回收 \(reclaimed)"
            text += "，已装保留 \(reclaimKeptInstalled)，未能核验 \(reclaimUnverified)"
            if reclaimSample.isEmpty == false {
                text += "，示例 \(reclaimSample.joined(separator: "、"))"
                if reclaimCandidates > reclaimSample.count { text += " 等" }
            }
        }
        if let reclaimAborted {
            // 「中止」必须显眼：否则 `回收 0` 会被读成「形态没匹配上」，
            // 而实际是通道不可信 —— 两者的后续动作完全不同。
            text += "，回收中止：\(reclaimAborted)"
        }
        return text
    }
}

/// 自替换结算后的显式清理请求：锚定到具体事务与刚确认的安装身份。
struct ProfileCleanupRequest: Sendable, Equatable {
    let transactionID: UUID
    let bundleIdentifier: String
    let keepingProfileUUID: String
    let installedIdentityReadAt: Date
    /// Seal 记录里出现过的全部 Bundle ID（含扩展）—— 见 `ProfileReclaimPolicy`。
    ///
    /// **必须由调用方从记录现算**，不能留空：这条路径的保留集合只有 Seal 自己一个条目，
    /// 少了这个集合，其它 App 的 Bundle ID 全会变成回收候选，而它们的**扩展**
    /// 靠设备端核验救不回来（扩展不是独立安装的 App，`isAppInstalled` 恒为 false）。
    let protectedBundleIDs: Set<String>
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
///
/// - Parameter reclaimSealOrphans: 是否额外回收「Seal 生成过、但设备上已没有对应
///   已安装 App」的 profile（换 Apple ID 后旧 Team 后缀留下的那一批，实测可达 30+ 份）。
///   开启后每一条都要过设备端核验，**确认没装才删**；且核验通道要先通过阳性对照，
///   任一环不通过就整轮不删。判据见 `ProfileReclaimPolicy`。
///
/// ## ⚠️ `protectedBundleIDs` 为什么是**必填**、没有默认值
///
/// 它回答的是「谁**不许**成为回收候选」，与 `keepingByBundleID`（回答「留哪一份」）
/// 是**两个不同的集合**，见 `ProfileReclaimPolicy.isReclaimableOrphan` 的说明。
///
/// 不留默认值是为了让**将来新增的调用点**必须显式回答这个问题 ——
/// 留 `= []` 就等于「忘了传 ⇒ 保护范围为空 ⇒ 删多」，而这条错法在真机上是
/// **静默删数据**（2026-09-17 已真实发生）。宁可让它编译不过。
protocol StaleProfileSweeping: Sendable {
    func sweepStaleProfiles(
        keepingByBundleID: [String: String],
        protectedBundleIDs: Set<String>,
        reclaimSealOrphans: Bool
    ) async -> ProfileCleanupSummary
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
    ///
    /// - Parameter reclaimSealOrphans: 同 `StaleProfileSweeping` 的说明。
    /// - Parameter protectedBundleIDs: 同 `StaleProfileSweeping` 的说明（**必填**）。
    @discardableResult
    static func removeStaleProfiles(
        for bundleIdentifier: String,
        keeping keepingProfileUUID: String?,
        protectedBundleIDs: Set<String>,
        reclaimSealOrphans: Bool = false
    ) async -> ProfileCleanupSummary {
        guard let keepingProfileUUID,
              keepingProfileUUID.isEmpty == false,
              bundleIdentifier.isEmpty == false else {
            return ProfileCleanupSummary(stage: "skipped-no-keeping-uuid")
        }
        return await removeStaleProfiles(
            keepingByBundleID: [bundleIdentifier: keepingProfileUUID],
            protectedBundleIDs: protectedBundleIDs,
            reclaimSealOrphans: reclaimSealOrphans
        )
    }

    /// 按 Bundle ID 批量清理。每个 Bundle ID 只保留 map 里指定的那一份 profile，
    /// 其余同 Bundle ID 的设备端 profile 全部删除。
    ///
    /// 空 map 或整份 map 都无效时**什么都不做**：没有明确「保留哪一份」就不删，
    /// 因为删掉正在用的那一份会让已安装的 App 立刻无法启动（iOS 启动时会校验 profile）。
    ///
    /// - Parameter reclaimSealOrphans: 见 `StaleProfileSweeping`。默认 `false` ——
    ///   这条路径会删设备端数据，必须由调用方显式开启。
    /// - Parameter protectedBundleIDs: 见 `StaleProfileSweeping`（**必填**）。
    @discardableResult
    static func removeStaleProfiles(
        keepingByBundleID: [String: String],
        protectedBundleIDs: Set<String>,
        reclaimSealOrphans: Bool = false
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
        return await removeProfiles(
            keepingByBundleID: normalized,
            protectedBundleIDs: protectedBundleIDs,
            reclaimSealOrphans: reclaimSealOrphans
        )
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

    /// 设备端「该 Bundle ID 装了没」的**三态**核验。
    ///
    /// 用会**抛错**的 `Minimuxer.isAppInstalled` 而不是 `Minimuxer.lookupApp`：
    /// 后者的 `nil` **同时**表示「没装」与「查询失败」，拿它当判据会在隧道抖动时
    /// 把「正在用」读成「没装」⇒ 删掉正在用的 profile ⇒ 对应 App 立刻无法启动。
    /// 详见 `ProfileReclaimPolicy.InstallProbe`。
    ///
    /// 放到 `Task.detached` 上：`isAppInstalled` 是同步阻塞 FFI，
    /// 与 `InstalledAppDeviceVerifier` 的既有做法一致。
    ///
    /// **刻意不调 `Install.resetProvider()`**（虽然 `InstalledAppDeviceVerifier` 会调）：
    /// 本函数跑在「刚装完一个 App」与「自替换结算」两个时间点上，此刻可能有
    /// installation_proxy 连接正在服务，重置会把它拆掉（R05：同一个 Bundle ID 上
    /// 不能有两个并发 installd 命令）。缓存连接失效的代价已经由**阳性对照**兜住 ——
    /// 那种情况下对照会抛错或答错，直接中止整轮，方向是安全的。
    private static func probeInstalled(
        bundleID: String
    ) async -> ProfileReclaimPolicy.InstallProbe {
        do {
            let installed = try await Task.detached(priority: .utility) {
                try Minimuxer.isAppInstalled(bundleId: bundleID)
            }.value
            return installed ? .installed : .notInstalled
        } catch {
            return .unavailable
        }
    }

    private static func removeProfiles(
        keepingByBundleID: [String: String],
        protectedBundleIDs: Set<String>,
        reclaimSealOrphans: Bool
    ) async -> ProfileCleanupSummary {
        var summary = ProfileCleanupSummary()
        let reader = ProvisioningProfileReader()
        let fileManager = FileManager.default
        let workingDir = fileManager.temporaryDirectory
            .appendingPathComponent("seal-profile-clean-\(UUID().uuidString)", isDirectory: true)

        defer { try? fileManager.removeItem(at: workingDir) }

        /// 删一份并记下首个错误。抽成局部函数，避免「保留集合」与「孤儿回收」
        /// 两条路径各写一遍同样的 do/catch —— 那种重复迟早会漂移成
        /// 「修了一条、漏了另一条」，本仓库反复踩过。
        /// 返回是否删除成功；计数由调用方按自己的口径累加（`removed` / `reclaimed`）。
        func removeProfile(_ uuid: String) -> Bool {
            do {
                try Provision.removeProvisioningProfile(id: uuid)
                return true
            } catch {
                if summary.firstError == nil {
                    summary.firstError = "remove失败: \(String(describing: error))"
                }
                return false
            }
        }

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

        // ── 阶段 A：本地判定（不需要问设备）────────────────────────────────
        // 路径 1 只用本地知识（keep-map）就能决定去留；路径 2 只**收集候选**，
        // 真正的删除要等阶段 B 的设备端核验。
        // 拆成两段是为了能在删**任何一份**孤儿之前先做阳性对照 —— 否则对照失败时
        // 已经删掉的那些收不回来。
        //
        // ⚠️ 回收还必须配一个**非空**的受保护集合（`protectedBundleIDs`）。
        // 它回答「谁不许成为候选」，与 `keepingByBundleID`（回答「留哪一份」）
        // 是两个集合。少了它，保护范围就等于只有 keep-map 里的那几条 ⇒ 其它 App 的
        // Bundle ID（尤其是**扩展**，设备端核验对它们恒为「没装」）会被当成孤儿删掉。
        // 这条错法是**静默删数据**，所以这里 fail closed：集合为空就整轮不回收，
        // 而不是「按现有信息尽量删」。
        let reclaimEnabled = reclaimSealOrphans && protectedBundleIDs.isEmpty == false
        if reclaimSealOrphans && protectedBundleIDs.isEmpty {
            summary.reclaimAborted = "无受保护集合（记录为空或未传入）"
        }
        var handledUUIDs = Set<String>()
        var reclaimCandidates: [(uuid: String, bundleID: String)] = []
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

            let loweredBundleID = profileBundleID.lowercased()

            // 路径 1：保留集合内的 Bundle ID，只留指定那一份。
            if let keepingUUID = keepingByBundleID[loweredBundleID] {
                summary.matched += 1
                if profileUUID.lowercased() == keepingUUID { continue }
                if removeProfile(profileUUID) { summary.removed += 1 } else { summary.removeFailed += 1 }
                continue
            }

            // 路径 2：集合外的「Seal 生成孤儿」（换 Apple ID 后的旧 Team 后缀）。
            // 默认关闭；开启时也**只是候选**，要过阶段 B 才删。
            guard reclaimEnabled,
                  ProfileReclaimPolicy.isReclaimableOrphan(
                      bundleID: profileBundleID,
                      keepingByBundleID: keepingByBundleID,
                      protectedBundleIDs: protectedBundleIDs
                  ) else {
                continue
            }
            reclaimCandidates.append((profileUUID, profileBundleID))
        }

        guard reclaimCandidates.isEmpty == false else { return summary }
        summary.reclaimCandidates = reclaimCandidates.count
        // 用闭包而不是 `map(\.bundleID)`：**Swift 不支持元组元素的 key path**，
        // 写了会编译失败，而本机没有 Swift 工具链，只能等云构建暴露。
        summary.reclaimSample = reclaimCandidates
            .prefix(ProfileCleanupSummary.reclaimSampleLimit)
            .map { $0.bundleID }

        // ── 阶段 B：设备端核验后才删 ───────────────────────────────────────
        // 阳性对照：Seal 自己**一定**装着（这段代码正在它里面跑），
        // 所以「连它都答未安装」只可能是通道不可信。没有可用的对照 Bundle ID
        // 就证明不了通道可信 ⇒ 一份都不删。
        guard let controlBundleID = Bundle.main.bundleIdentifier,
              controlBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            summary.reclaimAborted = "无阳性对照 Bundle ID"
            return summary
        }
        let positiveControlPassed = await probeInstalled(bundleID: controlBundleID) == .installed
        guard positiveControlPassed else {
            summary.reclaimAborted = "阳性对照未通过（\(controlBundleID) 被答成未安装）"
            return summary
        }

        // 中止是**整轮**的：一旦出现不可信的核验结果，后面每条都不再问设备。
        // 写成「先记原因、循环外统一收尾」而不是在 `case` 里直接 `return`，
        // 是为了让「中止影响整个 pass」这件事在代码形状上就看得出来 ——
        // 守卫断言的就是这一句（改成 `continue` 只跳过当前这条，保护等于没有）。
        var reclaimAbortReason: String?
        for candidate in reclaimCandidates {
            let probe = await probeInstalled(bundleID: candidate.bundleID)
            switch ProfileReclaimPolicy.decision(
                probe: probe,
                positiveControlPassed: positiveControlPassed
            ) {
            case .keepInstalled:
                // 「同一个 App 用两个 Team 各装一份」时走这里 —— 那份 profile 不能删。
                summary.reclaimKeptInstalled += 1
            case .reclaim:
                if removeProfile(candidate.uuid) { summary.reclaimed += 1 } else { summary.removeFailed += 1 }
            case .abortPass:
                // 走到这里只可能是 `probe == .unavailable`（阳性对照已在上面通过），
                // 但仍按实际 probe 记，避免将来重构后计数失去意义。
                if probe == .unavailable { summary.reclaimUnverified += 1 }
                reclaimAbortReason = "核验通道不可信（\(candidate.bundleID)：\(probe.logName)）"
                if summary.firstError == nil {
                    summary.firstError = "核验中止: \(candidate.bundleID) (\(probe.logName))"
                }
            }
            if reclaimAbortReason != nil { break }
        }
        summary.reclaimAborted = reclaimAbortReason
        return summary
    }
}

extension DeviceProfileCleaner: StaleProfileSweeping {
    func sweepStaleProfiles(
        keepingByBundleID: [String: String],
        protectedBundleIDs: Set<String>,
        reclaimSealOrphans: Bool
    ) async -> ProfileCleanupSummary {
        await Self.removeStaleProfiles(
            keepingByBundleID: keepingByBundleID,
            protectedBundleIDs: protectedBundleIDs,
            reclaimSealOrphans: reclaimSealOrphans
        )
    }
}

extension DeviceProfileCleaner: SelfReplacementProfileCleaning {
    /// 结算后的精准清理：清理前重读当前运行身份，只有主程序 profile 仍等于
    /// 结算时确认的 `keepingProfileUUID` 才删除旧 profile；身份已变化或不可读
    /// 时整批放弃，绝不误删正在使用的 profile。清理失败只进摘要，不回滚已确认身份。
    ///
    /// 开启 `reclaimSealOrphans`：Seal 自己换过 Apple ID 后会留下
    /// `com.mjorb.seal.<旧 team>` 的 profile（实测 5 个 team 变体）。
    /// 当前正在运行的那一份由 keep-map（路径 1）保住，根本不会成为候选；
    /// 其余变体要过设备端核验 —— 见 `removeProfiles` 阶段 B 的阳性对照。
    ///
    /// ⚠️ **本路径的 keep-map 只有 Seal 自己一个条目**（`removeStaleProfiles(for:keeping:)`
    /// 内部构造），所以其它 App 的 Bundle ID 全都是「候选」。主 App 靠设备端核验能救回来，
    /// **扩展救不回来**（扩展不是独立安装的 App，`isAppInstalled` 恒为 `false`）——
    /// 2026-09-17 真机上就是这么丢掉已装 App 三个扩展的 profile 的。
    /// ⇒ `request.protectedBundleIDs` 是这条路径**唯一**能保护扩展的东西，
    /// 它为空时 `removeProfiles` 会 fail closed（整轮不回收）。
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
            keeping: request.keepingProfileUUID,
            protectedBundleIDs: request.protectedBundleIDs,
            reclaimSealOrphans: true
        )
    }
}
