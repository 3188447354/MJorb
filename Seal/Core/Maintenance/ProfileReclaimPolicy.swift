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
    /// - Parameters:
    ///   - bundleID: 设备端 profile 里的 Bundle ID（大小写不敏感）。
    ///   - keepingByBundleID: 当前在用的保留集合（key 需已小写）。
    static func isReclaimableOrphan(
        bundleID: String,
        keepingByBundleID: [String: String]
    ) -> Bool {
        let lowered = bundleID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard lowered.isEmpty == false else { return false }
        // 当前在用的由 keep-map 决定保留哪一份，不走这条路径。
        guard keepingByBundleID[lowered] == nil else { return false }
        // 标记前后都必须有内容：`com.foo.seal.` 本身不是一个 Bundle ID。
        guard let range = lowered.range(of: sealGeneratedMarker) else { return false }
        return range.lowerBound > lowered.startIndex
            && range.upperBound < lowered.endIndex
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
