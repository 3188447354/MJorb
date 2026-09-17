import Foundation
import Testing
@testable import Seal

/// `ProfileReclaimPolicy` 的判据测试。
///
/// 这条规则的错法**不会崩、不会编译失败、也不会跑挂别的单测** ——
/// 只会在真机上删掉正在用的 profile，让对应 App 立刻无法启动。
/// 所以这里要同时钉住两个方向：
///   1. 该回收的形态必须认得出来（否则功能空转、堆积继续）；
///   2. 当前在用的、以及**没带 Seal 标记**的必须认不出来（否则误删）。
@Suite("旧 Team 变体 profile 的回收判据")
struct ProfileReclaimPolicyTests {
    /// 真机实测的形态：普通 App = `<原始>.seal.<team>`。
    @Test
    func recognizesNormalAppVariant() {
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: "com.kdt.livecontainer.seal.3432ZHJUF9",
                keepingByBundleID: ["com.kdt.livecontainer.seal.KYRJV2U7WS": "LIVE-UUID"]
            )
        )
    }

    /// Seal 自己是 `com.mjorb.seal.<team>`，**没有**独立的 `.seal` 中缀段 ——
    /// 但 `morb.seal.<team>` 里仍含 `.seal.`，所以同一条规则能覆盖它。
    /// 这条容易在重构时被「优化」掉（看起来像特例），故单列一条。
    @Test
    func recognizesSealItselfWithoutSpecialCasing() {
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: "com.mjorb.seal.TB95F327DS",
                keepingByBundleID: ["com.mjorb.seal.KYRJV2U7WS": "LIVE-UUID"]
            )
        )
    }

    /// 当前在用的那一份绝不能是候选 —— 删了 Seal 自己（或任何 App）就起不来了。
    @Test
    func currentBundleIdentifierIsNeverACandidate() {
        let keep = ["com.kdt.livecontainer.seal.KYRJV2U7WS": "LIVE-UUID"]
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: "com.kdt.livecontainer.seal.KYRJV2U7WS",
                keepingByBundleID: keep
            ) == false
        )
    }

    /// 大小写不敏感：设备端返回的大小写不保证与记录一致。
    @Test
    func matchingIsCaseInsensitive() {
        let keep = ["com.kdt.livecontainer.seal.kyrjv2u7ws": "LIVE-UUID"]
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: "com.KDT.LiveContainer.Seal.KYRJV2U7WS",
                keepingByBundleID: keep
            ) == false
        )
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: "com.KDT.LiveContainer.Seal.3432ZHJUF9",
                keepingByBundleID: keep
            )
        )
    }

    /// **其它工具签的 App 必须认不出来**：AltStore / SideStore 用
    /// `<原始>.<teamID>`，没有 `.seal` 中缀。Seal 只该清自己的东西。
    @Test
    func otherToolsBundleIdentifiersAreNotTouched() {
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: "com.example.other.ABC1234567",
                keepingByBundleID: [:]
            ) == false
        )
    }

    /// 标记必须在**中间**：`com.foo.seal.` 这种尾随形式不是一个 Bundle ID，
    /// 前缀形式同理。留着它们只会让日志里出现一堆无意义的候选。
    @Test
    func markerMustHaveContentOnBothSides() {
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: ".seal.com.example",
                keepingByBundleID: [:]
            ) == false
        )
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: "com.example.seal.",
                keepingByBundleID: [:]
            ) == false
        )
    }

    @Test
    func blankBundleIdentifierIsNotACandidate() {
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: "   ",
                keepingByBundleID: [:]
            ) == false
        )
    }

    /// 前导 / 尾随空白要先裁掉再判 —— 设备端解析出的字段偶尔带空白。
    @Test
    func surroundingWhitespaceIsTrimmed() {
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: "  com.kdt.livecontainer.seal.3432ZHJUF9\n",
                keepingByBundleID: [:]
            )
        )
    }

    /// 标记常量的字面量被守卫断言钉住；这里再钉一次「它确实是 `.seal.`」，
    /// 避免将来有人把它改成 `".seal"`（那样 `xseal.y` 也会命中）。
    @Test
    func markerConstantIsTheDottedForm() {
        #expect(ProfileReclaimPolicy.sealGeneratedMarker == ".seal.")
    }
}

/// 设备端核验之后的**回收决策**测试。
///
/// 这是整条功能唯一的安全边界，而它的错法**不崩、不编译失败**，只在真机上删数据。
/// 所以每个分支都要有名字直白的用例 —— 尤其是「通道不可信时必须中止」这一组。
@Suite("回收决策：设备端核验之后才允许删")
struct ProfileReclaimDecisionTests {
    /// 通道健康 + 设备上确实没装 ⇒ 删。这是唯一允许删的组合。
    @Test
    func notInstalledWithHealthyChannelIsTheOnlyReclaimPath() {
        #expect(
            ProfileReclaimPolicy.decision(probe: .notInstalled, positiveControlPassed: true)
                == .reclaim
        )
    }

    /// 设备上装着 ⇒ 保留。哪怕阳性对照没过也一样保留 ——
    /// 「同一原始 IPA 用两个 Team 各装一份」时那份 profile 不能删（`AppRecord.swift:275`）。
    @Test
    func installedIsAlwaysKeptEvenWithoutPositiveControl() {
        #expect(
            ProfileReclaimPolicy.decision(probe: .installed, positiveControlPassed: true)
                == .keepInstalled
        )
        #expect(
            ProfileReclaimPolicy.decision(probe: .installed, positiveControlPassed: false)
                == .keepInstalled
        )
    }

    /// **最要命的一条**：查询抛错时绝不能当成「没装」。
    /// `Minimuxer.lookupApp` 的 `nil` 同时表示「没装」与「查询失败」，
    /// 拿它当判据就会在这里删掉正在用的 profile。
    @Test
    func unavailableNeverReclaims() {
        #expect(
            ProfileReclaimPolicy.decision(probe: .unavailable, positiveControlPassed: true)
                == .abortPass
        )
        #expect(
            ProfileReclaimPolicy.decision(probe: .unavailable, positiveControlPassed: false)
                == .abortPass
        )
    }

    /// 阳性对照没过（连「确定装着的那一个」都答成未安装）⇒ 通道不可信 ⇒ 中止整轮。
    /// 没有这一条，「隧道抖动 ⇒ 全部答成未安装 ⇒ 全删」的路径是敞开的。
    @Test
    func failedPositiveControlAbortsTheWholePass() {
        #expect(
            ProfileReclaimPolicy.decision(probe: .notInstalled, positiveControlPassed: false)
                == .abortPass
        )
    }

    /// 中止是**全局**的，不是逐条的：调用方收到 `.abortPass` 后必须停止整个循环。
    /// 这条用例把「模拟一整轮」写出来，钉住「不会因为后面还有候选就继续删」。
    @Test
    func abortPassStopsTheWholePassInsteadOfSkippingOneCandidate() {
        // 三个候选：第一个答未安装、第二个查询失败、第三个也会答未安装。
        let probes: [ProfileReclaimPolicy.InstallProbe] = [.notInstalled, .unavailable, .notInstalled]
        var decisions: [ProfileReclaimPolicy.Decision] = []
        var removed: [Int] = []

        for (index, probe) in probes.enumerated() {
            let decision = ProfileReclaimPolicy.decision(probe: probe, positiveControlPassed: true)
            decisions.append(decision)
            guard decision == .abortPass else {
                if decision == .reclaim { removed.append(index) }
                continue
            }
            break // ← 关键：中止后不再处理剩余候选
        }

        #expect(decisions == [.reclaim, .abortPass])
        // 中止发生在第二个候选 ⇒ 第三个候选**没有被询问**，也就没有被删。
        #expect(removed == [0])
    }

    /// 阳性对照没过时，一份都不该走到 `.reclaim`。
    @Test
    func noCandidateIsEverReclaimedWhenPositiveControlFails() {
        let allProbes: [ProfileReclaimPolicy.InstallProbe] = [.installed, .notInstalled, .unavailable]
        for probe in allProbes {
            let decision = ProfileReclaimPolicy.decision(probe: probe, positiveControlPassed: false)
            #expect(decision != .reclaim, "对照没过时 \(probe) 不该被判为可回收")
        }
    }

    /// 三态必须各有自己的日志名 —— 「回收 0」到底是「形态没匹配」还是「通道不可信」，
    /// 全靠这几个字区分。
    @Test
    func probeStatesHaveDistinctLogNames() {
        let names = [
            ProfileReclaimPolicy.InstallProbe.installed.logName,
            ProfileReclaimPolicy.InstallProbe.notInstalled.logName,
            ProfileReclaimPolicy.InstallProbe.unavailable.logName,
        ]
        #expect(Set(names).count == 3)
        #expect(names.allSatisfy { $0.isEmpty == false })
    }
}
