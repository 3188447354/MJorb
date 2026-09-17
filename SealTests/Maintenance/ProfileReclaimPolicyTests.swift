import Foundation
import Testing
@testable import Seal

/// `ProfileReclaimPolicy` 的判据测试。
///
/// 这条规则的错法**不会崩、不会编译失败、也不会跑挂别的单测** ——
/// 只会在真机上删掉正在用的 profile，让对应 App 立刻无法启动。
/// 所以这里要同时钉住两个方向：
///   1. 该回收的形态必须认得出来（否则功能空转、堆积继续）；
///   2. 当前在用的、受保护的、以及**没带 Seal 标记**的必须认不出来（否则误删）。
///
/// 判据里有**两个集合**，别混淆（2026-09-17 真机事故的成因就是合成一个）：
///   - `keepingByBundleID`（严格）：决定「同一 Bundle ID 的多份 profile 留哪一份」；
///   - `protectedBundleIDs`（宽松）：决定「谁**不许**成为候选」。
@Suite("旧 Team 变体 profile 的回收判据")
struct ProfileReclaimPolicyTests {
    /// 真机实测的形态：普通 App = `<原始>.seal.<team>`。
    @Test
    func recognizesNormalAppVariant() {
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: "com.kdt.livecontainer.seal.3432ZHJUF9",
                keepingByBundleID: ["com.kdt.livecontainer.seal.KYRJV2U7WS": "LIVE-UUID"],
                protectedBundleIDs: []
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
                keepingByBundleID: ["com.mjorb.seal.KYRJV2U7WS": "LIVE-UUID"],
                protectedBundleIDs: []
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
                keepingByBundleID: keep,
                protectedBundleIDs: []
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
                keepingByBundleID: keep,
                protectedBundleIDs: []
            ) == false
        )
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: "com.KDT.LiveContainer.Seal.3432ZHJUF9",
                keepingByBundleID: keep,
                protectedBundleIDs: []
            )
        )
    }

    // MARK: - 宽松受保护集合（`protectedBundleIDs`）

    /// **这条对应 2026-09-17 真机事故**：已装 App 的扩展 profile 被当孤儿删掉。
    ///
    /// 扩展不是独立安装的 App，`isAppInstalled` 对它恒为 `false` ——
    /// 设备端核验这道安全网**对扩展完全瞎**。所以扩展唯一的保护就是
    /// 「它的 Bundle ID 出现在宽松集合里 ⇒ 根本不成为候选」。
    ///
    /// 真机日志（构建 95）：`候选 4，回收 3，已装保留 1`，
    /// 示例里主 App 与它的三个扩展并列 —— 主 App 被设备核验救下，三个扩展全删。
    @Test
    func protectedExtensionIsNeverACandidate() {
        let extensionID = "com.example.livecontainer.seal.TEAM.ShareExtension"
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: extensionID,
                keepingByBundleID: [:],
                protectedBundleIDs: [extensionID]
            ) == false
        )
        // 同一个 ID 不在受保护集合里时，它确实**会**成为候选 ——
        // 否则上一条可能只是因为「形态没匹配上」而通过（绿着坏掉）。
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: extensionID,
                keepingByBundleID: [:],
                protectedBundleIDs: []
            )
        )
    }

    /// 受保护集合的比对也必须大小写不敏感 —— 两个集合走的是同一类字符串，
    /// 设备端返回的大小写不受我们控制。
    @Test
    func protectedSetMatchingIsCaseInsensitive() {
        let extensionID = "com.example.livecontainer.seal.TEAM.ShareExtension"
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: extensionID,
                keepingByBundleID: [:],
                protectedBundleIDs: [extensionID.lowercased()]
            ) == false
        )
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: extensionID.lowercased(),
                keepingByBundleID: [:],
                protectedBundleIDs: [extensionID.uppercased()]
            ) == false
        )
    }

    /// 受保护集合**只**负责「不删谁」，不负责放宽形态判据：
    /// 集合为空时，规则必须与从前完全一致（该认出来的仍然认出来）。
    @Test
    func emptyProtectedSetDoesNotWidenTheCandidateRule() {
        let orphan = "com.kdt.livecontainer.seal.3432ZHJUF9"
        let withEmptySet = ProfileReclaimPolicy.isReclaimableOrphan(
            bundleID: orphan,
            keepingByBundleID: [:],
            protectedBundleIDs: []
        )
        #expect(withEmptySet)
        // 没带 Seal 标记的仍不能成为候选（不能因为集合为空就「什么都当候选」）。
        let foreign = "com.example.other.ABC1234567"
        let foreignWithEmptySet = ProfileReclaimPolicy.isReclaimableOrphan(
            bundleID: foreign,
            keepingByBundleID: [:],
            protectedBundleIDs: []
        )
        #expect(foreignWithEmptySet == false)
    }

    /// **其它工具签的 App 必须认不出来**：AltStore / SideStore 用
    /// `<原始>.<teamID>`，没有 `.seal` 中缀。Seal 只该清自己的东西。
    @Test
    func otherToolsBundleIdentifiersAreNotTouched() {
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: "com.example.other.ABC1234567",
                keepingByBundleID: [:],
                protectedBundleIDs: []
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
                keepingByBundleID: [:],
                protectedBundleIDs: []
            ) == false
        )
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: "com.example.seal.",
                keepingByBundleID: [:],
                protectedBundleIDs: []
            ) == false
        )
    }

    @Test
    func blankBundleIdentifierIsNotACandidate() {
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: "   ",
                keepingByBundleID: [:],
                protectedBundleIDs: []
            ) == false
        )
    }

    /// 前导 / 尾随空白要先裁掉再判 —— 设备端解析出的字段偶尔带空白。
    @Test
    func surroundingWhitespaceIsTrimmed() {
        #expect(
            ProfileReclaimPolicy.isReclaimableOrphan(
                bundleID: "  com.kdt.livecontainer.seal.3432ZHJUF9\n",
                keepingByBundleID: [:],
                protectedBundleIDs: []
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

/// 宽松受保护集合的**构造**测试。
///
/// 它与严格 keep-map（`AppMaintenanceJob.profileKeepMap`）是两个集合：
/// 后者只在 `signedArtifactStatus == .installed` 时才收扩展（那个取舍本身是对的），
/// 但那个标记一旦陈旧，扩展 ID 就会掉出**保护范围** ⇒ 被当孤儿删掉。
/// 所以这里必须钉住「构造时不看 `signedArtifactStatus`」。
@Suite("受保护集合的构造：扩展无条件进集合")
struct ProfileReclaimProtectedSetTests {
    private func makeRecord(
        mapped: String?,
        preferred: String? = nil,
        status: SignedArtifactStatus?,
        extensions: [AppExtensionRecord] = []
    ) -> AppRecord {
        AppRecord(
            originalBundleIdentifier: "com.example.original",
            mappedBundleIdentifier: mapped,
            name: "受保护集合测试",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .imported,
            ipaRelativePath: "Apps/Test/Original.ipa",
            signedArtifactStatus: status,
            preferredBundleIdentifier: preferred,
            importedAt: Date(),
            extensions: extensions
        )
    }

    private func makeExtension(mapped: String?) -> AppExtensionRecord {
        AppExtensionRecord(
            name: "ShareExtension",
            originalBundleIdentifier: "com.example.ShareExtension",
            mappedBundleIdentifier: mapped
        )
    }

    /// 记录**不是** `.installed` 时，扩展 ID 仍然必须进宽松集合。
    /// 这是与严格 keep-map 的关键区别，也是这次真机事故的直接修法。
    @Test
    func extensionIsCollectedEvenWhenRecordIsNotMarkedInstalled() {
        let record = makeRecord(
            mapped: "com.example.seal.TEAM",
            status: .available,
            extensions: [makeExtension(mapped: "com.example.seal.TEAM.ShareExtension")]
        )
        let ids = ProfileReclaimPolicy.protectedBundleIDs(records: [record])
        #expect(ids.contains("com.example.seal.TEAM.ShareExtension"))
        #expect(ids.contains("com.example.seal.TEAM"))
    }

    /// 即使 `signedArtifactStatus` 完全缺失（`nil`），扩展也要进集合。
    @Test
    func extensionIsCollectedWhenStatusIsNil() {
        let record = makeRecord(
            mapped: "com.example.seal.TEAM",
            status: nil,
            extensions: [makeExtension(mapped: "com.example.seal.TEAM.ShareExtension")]
        )
        let ids = ProfileReclaimPolicy.protectedBundleIDs(records: [record])
        #expect(ids.contains("com.example.seal.TEAM.ShareExtension"))
    }

    /// 多个 App 的扩展都要收进来 —— 结算清理那条路径的保留集合只有 Seal 自己，
    /// 别的 App 全靠这个集合兜住。
    @Test
    func collectsExtensionsFromEveryRecord() {
        let first = makeRecord(
            mapped: "com.a.seal.TEAM",
            status: .installed,
            extensions: [makeExtension(mapped: "com.a.seal.TEAM.ShareExtension")]
        )
        let second = makeRecord(
            mapped: "com.b.seal.TEAM",
            status: .available,
            extensions: [makeExtension(mapped: "com.b.seal.TEAM.LiveProcess")]
        )
        let ids = ProfileReclaimPolicy.protectedBundleIDs(records: [first, second])
        #expect(ids.contains("com.a.seal.TEAM.ShareExtension"))
        #expect(ids.contains("com.b.seal.TEAM.LiveProcess"))
        #expect(ids.contains("com.a.seal.TEAM"))
        #expect(ids.contains("com.b.seal.TEAM"))
    }

    /// `mappedBundleIdentifier` 为空/全空白时要回退到 `preferredBundleIdentifier`
    /// （等价于重构前 `AppMaintenanceJob.profileKeepMap` 的写法），
    /// 而不是把空白串塞进集合（那样集合里会有一条永远匹配不上的垃圾）。
    @Test
    func fallsBackToPreferredIdentifierAndSkipsBlank() {
        let preferredOnly = makeRecord(mapped: nil, preferred: "com.example.seal.TEAM", status: nil)
        let ids = ProfileReclaimPolicy.protectedBundleIDs(records: [preferredOnly])
        #expect(ids.contains("com.example.seal.TEAM"))
        #expect(ids.contains("") == false)

        let blank = makeRecord(mapped: "   ", preferred: nil, status: nil)
        let blankIds = ProfileReclaimPolicy.protectedBundleIDs(records: [blank])
        #expect(blankIds.isEmpty)
    }

    /// `effectiveBundleID` 是「哪个字段代表生效的 Bundle ID」的**唯一**出处，
    /// 直接钉住它的行为。
    @Test
    func effectiveBundleIdentifierPrefersMappedThenPreferred() {
        #expect(
            ProfileReclaimPolicy.effectiveBundleID(mapped: "com.a", preferred: "com.b") == "com.a"
        )
        #expect(
            ProfileReclaimPolicy.effectiveBundleID(mapped: nil, preferred: "com.b") == "com.b"
        )
        #expect(
            ProfileReclaimPolicy.effectiveBundleID(mapped: "  com.a  ", preferred: nil) == "com.a"
        )
        #expect(
            ProfileReclaimPolicy.effectiveBundleID(mapped: "   ", preferred: nil) == nil
        )
        #expect(
            ProfileReclaimPolicy.effectiveBundleID(mapped: nil, preferred: nil) == nil
        )
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

/// 「扩展随父 App 一起保留」的判据。
///
/// ## 这一条修的是什么（2026-09-17 真机，构建 97）
///
/// 维护清理报了 `候选 4，回收 3，已装保留 1`，示例里主 App 与它的三个扩展并列 ——
/// 主 App 被设备端核验救下，**三个扩展全删**。
///
/// 根因：扩展不是独立安装的 App，`isAppInstalled` 对它**恒为 `false`** ⇒
/// 设备端核验对扩展完全瞎。此前扩展**只**靠 `protectedBundleIDs`（Seal 记录里出现过的
/// ID）保护，而那一刻主 App 不在记录里（重新安装 Seal 后记录被清空）——
/// 于是扩展失去全部保护。
///
/// 判据：iOS 给扩展分配的 Bundle ID 是 `<父 App 的 Bundle ID>.<扩展名>`，
/// 所以「父 App 已确认安装」⇒「这份扩展 profile 是随它一起装上去的」⇒ 必须保留。
@Suite("扩展随父 App 保留：前缀判据")
struct ProfileReclaimExtensionTests {
    private let installedParent: Set<String> = ["com.kdt.livecontainer.seal.3432ZHJUF9"]

    @Test
    func extensionOfAnInstalledCandidateIsRecognised() {
        let shareExtension = ProfileReclaimPolicy.isExtensionBundleID(
            "com.kdt.livecontainer.seal.3432ZHJUF9.ShareExtension",
            ofAnyOf: installedParent
        )
        #expect(shareExtension)

        let liveProcess = ProfileReclaimPolicy.isExtensionBundleID(
            "com.kdt.livecontainer.seal.3432ZHJUF9.LiveProcess",
            ofAnyOf: installedParent
        )
        #expect(liveProcess)
    }

    /// 前缀必须在**点**边界上：`...3432ZHJUF9` 不是 `...3432ZHJUF99` 的父。
    /// 少了这一条，同一个 Team 下的兄弟变体会互相「保护」，回收功能就废了。
    @Test
    func prefixMustEndOnADotBoundary() {
        let sibling = ProfileReclaimPolicy.isExtensionBundleID(
            "com.kdt.livecontainer.seal.3432ZHJUF99",
            ofAnyOf: installedParent
        )
        #expect(sibling == false)
    }

    /// 父 App 没装 ⇒ 它那份扩展 profile 是死重量，照旧可回收。
    /// 这条是「别把回收功能整个废掉」的护栏。
    @Test
    func extensionOfANonInstalledParentIsNotProtected() {
        let orphan = ProfileReclaimPolicy.isExtensionBundleID(
            "com.kdt.livecontainer.seal.OLD_TEAM.ShareExtension",
            ofAnyOf: installedParent
        )
        #expect(orphan == false)
    }

    /// 大小写不敏感 —— 设备端返回的形态不受我们控制。
    @Test
    func matchingIsCaseInsensitive() {
        let mixedCase = ProfileReclaimPolicy.isExtensionBundleID(
            "COM.KDT.LiveContainer.Seal.3432zhjuf9.ShareExtension",
            ofAnyOf: installedParent
        )
        #expect(mixedCase)
    }

    /// 空的「已装候选」集合 ⇒ 谁都不算扩展 ⇒ 一个都不多留。
    /// 方向必须是这样：集合为空时**不多留**，否则一次记录读取失败就会让回收整体失效。
    @Test
    func emptyInstalledSetProtectsNothing() {
        let nothingProtected = ProfileReclaimPolicy.isExtensionBundleID(
            "com.kdt.livecontainer.seal.3432ZHJUF9.ShareExtension",
            ofAnyOf: []
        )
        #expect(nothingProtected == false)
    }

    /// 候选自己不能算自己的扩展（父 App 自己就是候选时，它该走 `installed` 那条分支）。
    @Test
    func aBundleIdentifierIsNotItsOwnExtension() {
        let itself = ProfileReclaimPolicy.isExtensionBundleID(
            "com.kdt.livecontainer.seal.3432ZHJUF9",
            ofAnyOf: installedParent
        )
        #expect(itself == false)
    }

    /// 空字符串不该匹配上任何东西（否则空串会成为所有人的「父」）。
    @Test
    func blankIdentifiersNeverMatch() {
        let blankCandidate = ProfileReclaimPolicy.isExtensionBundleID("   ", ofAnyOf: installedParent)
        #expect(blankCandidate == false)

        let blankParent = ProfileReclaimPolicy.isExtensionBundleID(
            "com.kdt.livecontainer.seal.3432ZHJUF9.ShareExtension",
            ofAnyOf: ["  "]
        )
        #expect(blankParent == false)
    }
}
