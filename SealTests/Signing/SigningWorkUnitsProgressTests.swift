import Foundation
import Testing
@testable import Seal

/// 「环上的每一个百分比都必须有出处」这组判据的守卫测试。
///
/// 背景（2026-09-19 设计讨论）：界面原先只有 `.pushing` 一个阶段有真值，其余阶段要么
/// 按 τ 爬估算（被用户否掉：「圈圈不要假预估」），要么全程静止（被读成卡死）。
/// 现在的第三条路是**数工作单元** —— 有计数就给数字，没有就转弧、环心不放数字。
/// 这一组测试钉的就是「什么时候才允许出现数字」以及「计数被污染时的方向」。
struct SigningWorkUnitsProgressTests {

    /// 完全没有任何信号的阶段：不许出现数字，且值必须正好停在地板上。
    @Test
    func stagesWithoutAnySignalStayOnTheFloor() {
        for stage in SigningStage.allCases {
            #expect(SigningProgressBudget.hasRealSignal(
                stage: stage, realProgress: nil, workUnits: nil
            ) == false, "\(stage) 不该被判定为有真实信号")
            #expect(SigningProgressBudget.confirmedProgress(
                stage: stage, realProgress: nil, workUnits: nil
            ) == SigningProgressBudget.plan(for: stage).floor)
        }
    }

    /// 跨阶段的残留计数必须被忽略 —— 否则「App ID 注册完了」会把签名阶段拽成 100%。
    @Test
    func staleUnitsFromAnotherStageAreIgnored() {
        let finished = SigningWorkUnits(stage: .preparingAppID, done: 9, total: 9)
        #expect(SigningProgressBudget.hasRealSignal(
            stage: .signing, realProgress: nil, workUnits: finished
        ) == false)
        #expect(SigningProgressBudget.confirmedProgress(
            stage: .signing, realProgress: nil, workUnits: finished
        ) == SigningProgressBudget.plan(for: .signing).floor)
    }

    /// 天花板是硬上界：`done >= total`、甚至计数超发，都不许越过 ceiling。
    @Test
    func unitsNeverClaimMoreThanTheCeiling() {
        let plan = SigningProgressBudget.plan(for: .preparingAppID)
        for units in [
            SigningWorkUnits(stage: .preparingAppID, done: 9, total: 9),
            SigningWorkUnits(stage: .preparingAppID, done: 20, total: 9)
        ] {
            #expect(SigningProgressBudget.confirmedProgress(
                stage: .preparingAppID, realProgress: nil, workUnits: units
            ) == plan.ceiling)
        }
    }

    /// 除零与负数不是「0%」，而是「没有可信信号」—— 方向很重要：
    /// 报 0% 会被读成「一步都没做」，而实际上我们只是不知道。
    @Test
    func unusableCountsAreNoSignalRatherThanZeroPercent() {
        #expect(SigningWorkUnits(stage: .preparingAppID, done: 3, total: 0).fraction == nil)
        #expect(SigningWorkUnits(stage: .preparingAppID, done: -1, total: 9).fraction == nil)
        #expect(SigningProgressBudget.hasRealSignal(
            stage: .preparingAppID, realProgress: nil,
            workUnits: SigningWorkUnits(stage: .preparingAppID, done: 3, total: 0)
        ) == false)
    }

    /// 字节进度只在 `.pushing` 采信；别的阶段即使收到残留值也不许被它拽动。
    @Test
    func byteProgressIsAdoptedByPushingOnly() {
        let plan = SigningProgressBudget.plan(for: .pushing)
        #expect(SigningProgressBudget.confirmedProgress(
            stage: .pushing, realProgress: 0.5, workUnits: nil
        ) == plan.floor + (plan.ceiling - plan.floor) * 0.5)
        #expect(SigningProgressBudget.confirmedProgress(
            stage: .signing, realProgress: 0.5, workUnits: nil
        ) == SigningProgressBudget.plan(for: .signing).floor)
    }

    /// 真值行只接受「本阶段 + 有总量」的计数；没有可数对象的阶段不许编一行出来。
    @Test
    func unitsTextRejectsForeignStageAndUnusableTotal() {
        let units = SigningWorkUnits(stage: .preparingAppID, done: 4, total: 9)
        #expect(SigningStage.preparingAppID.unitsText(units)?.contains("4 / 9") == true)
        #expect(SigningStage.signing.unitsText(units) == nil)
        #expect(SigningStage.preparingAppID.unitsText(nil) == nil)
        #expect(SigningStage.preparingAppID.unitsText(
            SigningWorkUnits(stage: .preparingAppID, done: 1, total: 0)
        ) == nil)
        // 结构上没有可数对象的阶段（用自己的计数喂也一样）⇒ 恒不产出真值行。
        // 注意 `.signing` / `.verifying` / `.preparingBundle` 不在此列：它们**有**可数对象
        //（可执行文件 / 核对项 / 解压条目），只是生产者目前还没接上。
        for stage in [SigningStage.waitingForChannel, .preparingAccount, .preparingCertificate,
                      .pushing, .installing] {
            #expect(stage.unitsText(SigningWorkUnits(stage: stage, done: 1, total: 2)) == nil,
                    "\(stage) 结构上没有可数对象，不该产出真值行")
        }
    }

    // MARK: - 批量续签接上同一根管（2026-09-21）
    //
    // 注：「预期说明」那一行已于 2026-09-21 按用户决定整条删掉（阶段名已经修对，
    // 解释行只是把抽屉堆满，而且最容易写出「替用户断言因果」那类被真机推翻的话）。
    // 它没有留任何测试 —— `SigningStage` 上已无 `expectationText`，谁想加回来必须先过编译器。

    /// 共用采信规则：同一阶段的**倒退**必须丢；换阶段、换总数都要收。
    @Test
    func sharedAcceptRuleDropsSameStageRegressionOnly() {
        let ten = SigningWorkUnits(stage: .preparingAppID, done: 10, total: 12)
        #expect(SigningWorkUnits.shouldAccept(ten, over: nil))
        #expect(SigningWorkUnits.shouldAccept(ten, over: ten))                // 同值不算倒退
        let nine = SigningWorkUnits(stage: .preparingAppID, done: 9, total: 12)
        #expect(SigningWorkUnits.shouldAccept(nine, over: ten) == false)     // 倒退 ⇒ 丢
        let grown = SigningWorkUnits(stage: .preparingAppID, done: 11, total: 12)
        #expect(SigningWorkUnits.shouldAccept(grown, over: ten))
        // 跨阶段：轨道自己会按 `stage` 过滤，采信这一层不拦（否则换阶段的第一次上报会被误丢）
        let profiles = SigningWorkUnits(stage: .preparingProfiles, done: 1, total: 12)
        #expect(SigningWorkUnits.shouldAccept(profiles, over: ten))
    }

    /// 批量会话：阶段内计数按共用规则采信，**跨阶段的上报**直接不收。
    @Test
    func batchSessionRecordsOnlyCurrentStageUnits() {
        var session = BatchRefreshSession()
        _ = session.advanceStage(.preparingAppID)
        session.recordWorkUnits(SigningWorkUnits(stage: .preparingProfiles, done: 9, total: 9))
        #expect(session.workUnits == nil)                                     // 别的阶段的值不许漏进来
        session.recordWorkUnits(SigningWorkUnits(stage: .preparingAppID, done: 4, total: 9))
        #expect(session.workUnits?.done == 4)
        session.recordWorkUnits(SigningWorkUnits(stage: .preparingAppID, done: 2, total: 9))
        #expect(session.workUnits?.done == 4)                                 // 倒退被丢
    }

    /// 换 App 时不许把上一项的 `9 / 9` 带进下一项的同名阶段。
    ///
    /// 这是批量特有的缺陷形态：单签一次只有一个 App，残留值靠 `stage` 过滤就够了；
    /// 批量里下一项会**重走同名阶段**，不主动清就会让新 App 的第一格直接画满。
    @Test
    func batchStageChangeResetsStageClockAndUnits() {
        var session = BatchRefreshSession()
        _ = session.advanceStage(.preparingAppID)
        session.recordWorkUnits(SigningWorkUnits(stage: .preparingAppID, done: 9, total: 9))
        #expect(session.stageStartedAt != nil)

        let later = Date().addingTimeInterval(30)
        _ = session.advanceStage(.preparingAccount, at: later)                 // 下一项从头开始
        #expect(session.workUnits == nil)
        #expect(session.stageStartedAt == later)

        _ = session.advanceStage(.preparingBundle, at: later.addingTimeInterval(5))
        #expect(session.stageStartedAt == later.addingTimeInterval(5))         // 换阶段就换起点
    }

    /// 有真值时轨道必须跟着真值走，而不是按 τ 爬（批量与单签共用同一个函数）。
    ///
    /// 取同一个 `elapsed = 999`：τ 收敛此时早已到顶（≈ 满格），而真值只承认 1/9 ⇒
    /// 若哪天有人把真值通道接掉，这条会立刻红。
    @Test
    func batchTrackUsesRealUnitsWhenPresent() {
        let units = SigningWorkUnits(stage: .preparingAppID, done: 1, total: 9)
        let withUnits = SigningProgressBudget.bucketFill(
            2, stage: .preparingAppID, elapsed: 999, realProgress: nil, workUnits: units)
        let estimateOnly = SigningProgressBudget.bucketFill(
            2, stage: .preparingAppID, elapsed: 999, realProgress: nil, workUnits: nil)
        #expect(withUnits < estimateOnly)     // 真值把「已经快满了」的估算压回 1/9
        #expect(withUnits > 0)
        // 对照：估算在这一格已经爬到本阶段的顶（格内有 2 个阶段 ⇒ 0.5），
        // 说明「没有真值时它一定会宣称快满了」——正是真值必须优先的理由。
        #expect(estimateOnly > 0.49)
    }
}
