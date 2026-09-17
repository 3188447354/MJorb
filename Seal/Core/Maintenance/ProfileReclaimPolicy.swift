import Foundation

/// 判断设备端的某份 profile 是否属于「Seal 生成过、但设备上已没有对应已安装 App」的孤儿，
/// 以及**在设备端核验之后**到底该不该删。
///
/// ## 背景（2026-09-17 从 19 份真机日志量化）
///
/// 用户用**多个 Apple ID 轮换**突破免费账号「3 个自签应用」上限。而
/// `BundleIDMapper.mainBundleID` 会**强制附加当前 team 后缀**，于是每换一个账号，
/// 每个 App 就多出一个 Bundle ID。实测：**19 个 base × 13 个 team = 39 个 Seal 生成过的
/// Bundle ID**，而 `AppMaintenanceJob.profileKeepMap` 的 key 只有**当前**在用的那些
/// ⇒ `removeProfiles` 里 `guard let keepingUUID = keepingByBundleID[...] else { continue }`
/// 让它们永远进不了 `matched`，`删除` 恒为 0。
///
/// ## 判据为什么是「`.seal.` 中缀」而不是「与记录里的 base 比对」
///
/// 1. **Seal 自己**：`com.mjorb.seal.<team>` —— 也含 `.seal.` 中缀
///    （`morb.seal.<team>`），所以同一条规则能覆盖，不需要给 Seal 开特例。
/// 2. **已从 Seal 列表里删掉的 App**：记录里没有 base 可比对，但 Bundle ID 仍是
///    `<原始>.seal.<team>` —— 只有中缀规则能捞到它们。真机上这类占多数。
/// 3. 其它工具（AltStore / SideStore）用的是 `<原始>.<teamID>`，**没有** `.seal` 中缀，
///    所以这条规则天然不会碰它们。
///
/// ## 为什么「像 Seal 生成的」不等于「可以删」
///
/// `AppRecord.swift:275` 明确写着：记录身份**不包含** `originalBundleIdentifier`，
/// 因为「**同一原始 IPA 可用不同 Bundle ID 签出多个副本同时安装**」。
/// 用户**可以**故意把同一个 App 用两个 Team 各装一份 —— 此时另一个 Team 的 profile
/// **不是**垃圾，删了那个 App 立刻无法启动。
///
/// ⇒ 本策略的 `isReclaimableOrphan` 只做**便宜的本地形态判断**，产出的只是**候选**。
/// 真正决定删不删的是 `decision(probe:positiveControlPassed:)`，它要求设备端核验。
///
/// 抽成纯函数是为了能单测 —— 这条规则的错法不会崩、不会编译失败，
/// 只会在真机上删掉正在用的 profile。守卫另有断言钉住「设备层真的用了会抛错的 API」。
enum ProfileReclaimPolicy {
    /// Seal 生成过的 Bundle ID 的标志：`.seal` 中缀。
    ///
    /// 两种形态都会命中：
    /// - 普通 App：`com.kdt.livecontainer.seal.3432ZHJUF9`
    /// - Seal 自己：`com.mjorb.seal.TB95F327DS`
    static let sealGeneratedMarker = ".seal."

    /// 是否为「可回收候选」。
    ///
    /// **只是候选** —— 还必须过 `decision(probe:positiveControlPassed:)` 才允许删除。
    ///
    /// ## ⚠️ 两个集合必须分开，绝不能合成一个
    ///
    /// - `keepingByBundleID`（**严格**）：决定「同一 Bundle ID 的多份 profile 留哪一份」。
    ///   它**刻意**宁缺勿滥 —— 拿不到可信 UUID 就整条不进集合。
    /// - `protectedBundleIDs`（**宽松**）：决定「谁**不许**成为候选」。只要 Seal 记录里
    ///   出现过这个 Bundle ID 就进来，**不要求** `signedArtifactStatus == .installed`。
    ///
    /// 判据永远是「**宽松的决定不删，严格的决定留哪份**」。
    /// 反过来用严格集合决定删谁，一定会删多 —— 2026-09-17 真机就是这么丢掉
    /// 已装 App 的扩展 profile 的（见 `protectedBundleIDs(records:)` 的说明）。
    ///
    /// - Parameters:
    ///   - bundleID: 设备端 profile 里的 Bundle ID（大小写不敏感）。
    ///   - keepingByBundleID: 当前在用的保留集合。**key 的大小写不敏感** —— 见下。
    ///   - protectedBundleIDs: Seal 记录里出现过的全部 Bundle ID（含扩展）。
    static func isReclaimableOrphan(
        bundleID: String,
        keepingByBundleID: [String: String],
        protectedBundleIDs: Set<String>
    ) -> Bool {
        let lowered = normalized(bundleID)
        guard lowered.isEmpty == false else { return false }
        // 当前在用的由 keep-map 决定保留哪一份，不走这条路径。
        //
        // ⚠️ 这里**必须**按大小写不敏感比对，不能写成 `keepingByBundleID[lowered] == nil`。
        // 调用方（`DeviceProfileCleaner.removeStaleProfiles`）确实会把 key 归一化成小写，
        // 但这条判断的错法方向是**删掉正在用的 profile**（对应 App 立刻无法启动），
        // 不能靠「调用方一定记得转小写」这种约定来保证安全。
        // 2026-09-17 被单测当场证伪：`currentBundleIdentifierIsNeverACandidate` 传了
        // 混合大小写的 key，精确查表没命中 ⇒ 把「正在用的那个」判成了可回收。
        guard keepingByBundleID.keys.contains(where: { normalized($0) == lowered }) == false else {
            return false
        }
        // ② 宽松集合：Seal 记录里出现过的一律不当候选。
        //
        // 这一条是**扩展的唯一保护**：扩展不是独立安装的 App，
        // `isAppInstalled` 对它恒为 `false`，`decision` 里的设备端核验完全瞎。
        // 少了这一条，已装 App 的扩展 profile 会被删掉（真机上真的发生过）。
        guard protectedBundleIDs.contains(where: { normalized($0) == lowered }) == false else {
            return false
        }
        // 标记前后都必须有内容：`com.foo.seal.` 本身不是一个 Bundle ID。
        guard let range = lowered.range(of: sealGeneratedMarker) else { return false }
        return range.lowerBound > lowered.startIndex
            && range.upperBound < lowered.endIndex
    }

    /// 归一化：去空白 + 小写。Bundle ID 大小写不敏感，查表前一律走这里。
    static func normalized(_ bundleID: String) -> String {
        bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 「记录里哪个字段代表生效的 Bundle ID」—— **唯一**出处。
    ///
    /// `mappedBundleIdentifier` 优先，为空/全空白时回退 `preferredBundleIdentifier`。
    /// 提取出来是因为 `AppMaintenanceJob.profileKeepMap` 与 `protectedBundleIDs(records:)`
    /// 都要用它 —— 同一规则抄两份，迟早漂移。
    static func effectiveBundleID(mapped: String?, preferred: String?) -> String? {
        guard let raw = mapped ?? preferred else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 构造**宽松**的「受保护 Bundle ID 集合」：Seal 记录里出现过的全部 Bundle ID。
    ///
    /// ## 为什么扩展必须**无条件**进来（不看 `signedArtifactStatus`）
    ///
    /// `AppMaintenanceJob.profileKeepMap` 只把扩展收进**严格**集合、且要求
    /// `signedArtifactStatus == .installed`。那个取舍本身是对的（安装失败时扩展记录指向
    /// 设备上并不存在的 profile，拿它当保留集合会把真在用的那份删掉）。
    ///
    /// 但它有个**没被考虑到的另一侧**：严格集合同时被当成了「候选过滤集合」，
    /// 于是那个标记一旦陈旧，扩展 ID 就掉出保护范围 ⇒ 变成回收候选。
    /// 而扩展的设备端核验恒为「没装」⇒ 直接删掉正在用的扩展 profile。
    ///
    /// 真机实证（2026-09-17，构建 95）：
    /// `候选 4，回收 3，已装保留 1`，示例里主 App 与它的三个扩展并列 ——
    /// 主 App 被设备端核验救下，三个扩展全删。
    ///
    /// ⇒ 宽松集合**只**用来回答「谁不许成为候选」，不回答「留哪一份」，
    /// 所以这里可以（也必须）宁滥勿缺。
    static func protectedBundleIDs(records: [AppRecord]) -> Set<String> {
        var ids: Set<String> = []
        for record in records {
            if let main = effectiveBundleID(
                mapped: record.mappedBundleIdentifier,
                preferred: record.preferredBundleIdentifier
            ) {
                ids.insert(main)
            }
            // ⚠️ 扩展**不**加 `signedArtifactStatus == .installed` 门槛，理由见上。
            for extensionRecord in record.extensions {
                if let extensionID = effectiveBundleID(
                    mapped: extensionRecord.mappedBundleIdentifier,
                    preferred: nil
                ) {
                    ids.insert(extensionID)
                }
            }
        }
        return ids
    }

    // MARK: - 设备端核验

    /// 「该 Bundle ID 在设备上装了没」的**三态**核验结果。
    ///
    /// 之所以必须是三态而不是 `Bool`：底层的
    /// `Minimuxer.lookupApp(bundleId:) -> String?` 把「没装」与「查询失败」
    /// **都折叠成 `nil`**（`Minimuxer.swift:254` 里 `try?` 吞掉了错误、
    /// `Device.getFirstDevice()` 失败也返回 nil）。拿它当判据 ⇒ 隧道一抖动，
    /// 所有候选都被读成「没装」⇒ 删掉正在用的 profile ⇒ 对应 App 立刻起不来。
    /// 所以这里只认会**抛错**的 `Minimuxer.isAppInstalled(bundleId:)`：
    /// 它把「设备/隧道不可达」表达成 throw，与「查到了但没装」严格分开。
    enum InstallProbe: Equatable {
        /// 设备上确实装着。
        case installed
        /// 查询成功、但设备上没有这个 Bundle ID。
        case notInstalled
        /// 查询本身失败（抛错）。**既不能当成「没装」，也不能当成「装了」。**
        case unavailable

        /// 进日志用的名字 —— 「中止回收」时要把是哪种失败写清楚，
        /// 否则「回收 0」和「形态没匹配上」在日志上分不开。
        var logName: String {
            switch self {
            case .installed: return "已安装"
            case .notInstalled: return "未安装"
            case .unavailable: return "查询失败"
            }
        }
    }

    /// 对某一份候选的处置。
    enum Decision: Equatable {
        /// 设备上确实没装 ⇒ 这份 profile 是死重量，删掉不可能破坏任何东西。
        case reclaim
        /// 设备上装着 ⇒ 保留（同一个 App 用两个 Team 各装一份时会出现）。
        case keepInstalled
        /// **中止整轮回收**（一份都不再删）。
        case abortPass
    }

    /// 回收决策 —— **这是这条功能唯一的安全边界**。
    ///
    /// 做成纯函数是因为它的错法「不崩、不编译失败、只在真机上删数据」，
    /// 只能靠单测 + 守卫断言钉住。
    ///
    /// - Parameters:
    ///   - probe: 该候选 Bundle ID 的设备端核验结果。
    ///   - positiveControlPassed: **阳性对照**是否通过 —— 即「拿一个**确定已安装**的
    ///     Bundle ID（Seal 自己，我们正在运行）去问，答的是 `.installed`」。
    ///
    /// 为什么需要阳性对照：`.unavailable` 只能抓到**抛错**的失败。而
    /// `RustInstProxy.lookup(appId:)` 内部把 RPC 失败也返回成 `nil`
    /// （`_rust_bridge_instproxy_lookup` 返回空指针 ⇒ `nil`），
    /// 这种**静默的**失败在单条查询上看不出来。阳性对照就是先证明
    /// 「这条通道此刻说真话」，再去信它对候选的回答。
    static func decision(
        probe: InstallProbe,
        positiveControlPassed: Bool
    ) -> Decision {
        switch probe {
        case .unavailable:
            // 抛错点（`Device.getFirstDevice()` / `RustIdevice.lookupApp`）都是
            // **全局性**的，不是某个 Bundle ID 特有的 ⇒ 通道已经不健康，
            // 后续查询给出的 `nil` 一律不可信，停止整轮。
            // 代价只是「本轮不回收」，下次维护再来。
            return .abortPass
        case .installed:
            return .keepInstalled
        case .notInstalled:
            // 阳性对照没过 ⇒ 连「确定装了的那一个」都答成没装 ⇒ 通道不可信。
            return positiveControlPassed ? .reclaim : .abortPass
        }
    }
}
