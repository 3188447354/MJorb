import Foundation
import Testing
@testable import Seal

/// 进度预算表与阶段轨道的规则。
///
/// 这些性质错了**不会崩、不会编译失败**，只会在真机上表现为：
/// 进度在阶段切换处跳一下或往回退、长阶段几十秒一动不动、轨道某格永远填不满。
/// 所以它们必须由单测钉住，而不是靠人肉读表。
///
/// ⚠️ 本文件里 `everyStageBudgetMeetsTheNextOne` 与 `theTwoLongStagesNoLongerStandStill`
/// 是守卫 R36 会去核对「确实存在」的两条断言 —— 删掉它们等于把这两条约束一起删掉，
/// 守卫会报红。
struct SigningProgressBudgetTests {

    @Test
    func everyStageBudgetMeetsTheNextOne() {
        // `ceiling_i == floor_{i+1}` 是整套估算**全部的连续性**所在：
        // 破坏它不会崩、不会报错，只会让进度在阶段切换时跳一下，或者数字往回退。
        let stages = SigningStage.allCases
        for index in 0..<(stages.count - 1) {
            let current = SigningProgressBudget.plan(for: stages[index])
            let next = SigningProgressBudget.plan(for: stages[index + 1])
            #expect(current.ceiling == next.floor)
        }
    }

    @Test
    func estimateNeverReachesItsCeiling() {
        for stage in SigningStage.allCases {
            let budget = SigningProgressBudget.plan(for: stage)
            #expect(budget.ceiling > budget.floor)
            // 0 秒时正好落在地板上（阶段刚进来的那一刻，数字不该比上一阶段结束时的位置高）。
            #expect(SigningProgressBudget.estimatedProgress(stage: stage, elapsed: 0) == budget.floor)
            // 20 个时间常数之后仍然**严格小于**天花板 ——
            // 「估算永远不会自己走到终点」是这套模型不编数字的全部保证。
            #expect(
                SigningProgressBudget.estimatedProgress(
                    stage: stage,
                    elapsed: budget.timeConstant * 20
                ) < budget.ceiling
            )
        }
    }

    @Test
    func progressIsMonotonicInsideAStage() {
        for stage in SigningStage.allCases {
            var previous = -1.0
            for step in 0...60 {
                let value = SigningProgressBudget.overallProgress(
                    stage: stage,
                    elapsed: Double(step),
                    realProgress: 0.5
                )
                #expect(value >= previous)
                previous = value
            }
        }
    }

    @Test
    func progressNeverGoesBackwardsAcrossStageBoundaries() {
        // 上一个阶段爬到最高时仍严格小于天花板，而天花板就是下一个阶段的地板
        // ⇒ 阶段切换处数字不会往回退。
        let stages = SigningStage.allCases
        for index in 0..<(stages.count - 1) {
            let before = SigningProgressBudget.plan(for: stages[index])
            let lastValue = SigningProgressBudget.estimatedProgress(
                stage: stages[index],
                elapsed: before.timeConstant * 20
            )
            let firstValue = SigningProgressBudget.estimatedProgress(
                stage: stages[index + 1],
                elapsed: 0
            )
            #expect(lastValue < firstValue)
        }
    }

    @Test
    func aFullRunNeverMovesTheNumberBackwards() {
        // 端到端的单调性：按阶段顺序走一遍、每个阶段取若干时间点，拼出的整条曲线
        // 必须单调不减。这是用户唯一能直接看到的那条性质。
        var previous = -1.0
        for stage in SigningStage.allCases {
            let budget = SigningProgressBudget.plan(for: stage)
            for step in 0...10 {
                let value = SigningProgressBudget.overallProgress(
                    stage: stage,
                    elapsed: budget.timeConstant * Double(step),
                    realProgress: nil
                )
                #expect(value >= previous)
                previous = value
            }
        }
    }

    @Test
    func onlyTheUploadStageUsesTheRealPercentage() {
        // 切到别的阶段后，安装通道回传的旧值必须被忽略 ——
        // 否则残留的 0.9 会把进度从「正在申请证书」拽回上传区间。
        for stage in SigningStage.allCases {
            let budget = SigningProgressBudget.plan(for: stage)
            let value = SigningProgressBudget.overallProgress(
                stage: stage,
                elapsed: 0,
                realProgress: 0.9
            )
            if budget.usesRealProgress {
                #expect(value == budget.floor + (budget.ceiling - budget.floor) * 0.9)
            } else {
                #expect(value == budget.floor)
            }
        }
    }

    @Test
    func confirmedProgressDoesNotDriftWithTime() {
        // 深色弧画的是「已确认到达」的位置：本阶段无论估算爬到哪里，它都停在阶段起点。
        // 这正是「浅色 = 估算」能被用户读出来的前提。
        for stage in SigningStage.allCases where SigningProgressBudget.isEstimated(stage: stage) {
            let budget = SigningProgressBudget.plan(for: stage)
            #expect(SigningProgressBudget.confirmedProgress(stage: stage, realProgress: nil) == budget.floor)
        }
    }

    @Test
    func bucketAdvancesByOneSlotWhenAStageCompletes() {
        // 同一格里的阶段完成时，格内填充要正好推进一格、且衔接处不跳：
        // 完成时逼近 (k+1)/total，下一阶段从 (k+1)/total 起。
        let stages = SigningStage.allCases
        for index in 0..<(stages.count - 1) {
            let before = stages[index]
            let after = stages[index + 1]
            let beforeBudget = SigningProgressBudget.plan(for: before)
            let afterBudget = SigningProgressBudget.plan(for: after)
            guard SigningProgressBudget.isEstimated(stage: before),
                  beforeBudget.bucket == afterBudget.bucket else { continue }
            let atEnd = SigningProgressBudget.bucketFill(
                beforeBudget.bucket,
                stage: before,
                elapsed: beforeBudget.timeConstant * 20,
                realProgress: nil
            )
            let atStart = SigningProgressBudget.bucketFill(
                afterBudget.bucket,
                stage: after,
                elapsed: 0,
                realProgress: nil
            )
            #expect(atEnd < 1)
            #expect(atStart > atEnd)
        }
    }

    @Test
    func everyStageLandsInExactlyOneBucket() {
        // 轨道格数是写死的 5，而阶段数会变 —— 这条断言保证「每个阶段都被某一格接住」。
        // 漏掉一个阶段的话，它在轨道上会完全消失（不崩、不报错，只是那一格不动）。
        var total = 0
        for bucket in 0..<SigningProgressBudget.bucketCount {
            total += SigningProgressBudget.bucketTotal(bucket)
        }
        #expect(total == SigningStage.allCases.count)
        for stage in SigningStage.allCases {
            let budget = SigningProgressBudget.plan(for: stage)
            #expect(budget.bucket >= 0)
            #expect(budget.bucket < SigningProgressBudget.bucketCount)
            #expect(budget.indexInBucket >= 0)
            #expect(budget.indexInBucket < SigningProgressBudget.bucketTotal(budget.bucket))
        }
    }

    @Test
    func theTwoLongStagesNoLongerStandStill() {
        // 这条是本次改版的**目的**，不是实现细节。
        //
        // 抖音 780 MB 在 `.preparingBundle` 要 112 秒，而旧实现全程只显示写死的 23%
        //（用户据此判断「Apple ID 验证卡住了」，于是去重新验证 —— 正是限流死循环的入口）。
        // 现在它必须明显爬升。
        let bundle = SigningProgressBudget.overallProgress(
            stage: .preparingBundle,
            elapsed: 112,
            realProgress: nil
        )
        #expect(bundle > 30)
        // 但**绝不能**越过天花板，否则阶段切换时数字会往回退。
        #expect(bundle < SigningProgressBudget.plan(for: .preparingBundle).ceiling)

        // `.installing`：installd 不回进度，旧实现全程钉在 93%。现在它会爬到接近上界
        // 然后停住 —— 「永远不会声称装完」。
        let installing = SigningProgressBudget.overallProgress(
            stage: .installing,
            elapsed: 600,
            realProgress: nil
        )
        #expect(installing > 93)
        #expect(installing < 95)
    }

    @Test
    func installWaitNoteOwnsTheElapsedTextForInstallStages() {
        // `.installing` / `.verifying` 的等待文案由 `InstallWaitNote` 统一给出，
        // 卡片自己再报一遍会让同一个数字在同一张卡片上出现两次（看起来像故障）。
        #expect(SigningProgressBudget.showsOwnElapsed(stage: .installing, elapsed: 600) == false)
        #expect(SigningProgressBudget.showsOwnElapsed(stage: .verifying, elapsed: 600) == false)
        // 短暂阶段不显示计时：显示只会让人以为在拖时间。
        #expect(SigningProgressBudget.showsOwnElapsed(stage: .signing, elapsed: 1) == false)
        // 长阶段必须显示 —— `preparingBundle` 的 112 秒就是这条门槛存在的理由。
        #expect(SigningProgressBudget.showsOwnElapsed(stage: .preparingBundle, elapsed: 112))
    }

    @Test
    func stageStartResetsOnStageChangeAndHoldsOnRepeat() {
        let start = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 160)
        // 同一阶段被重复推送（`.pushing` / `.installing` 都有哨兵 + 补发）：
        // 每次都重置会让阶段内的估算永远停在起点，比不做估算更像卡死。
        #expect(InstallStageTimeline.stageStart(
            entering: .pushing, currentStage: .pushing, previous: start, now: later
        ) == start)
        // 阶段变了：必须重置，否则新阶段从上一个阶段的耗时开始爬。
        #expect(InstallStageTimeline.stageStart(
            entering: .installing, currentStage: .pushing, previous: start, now: later
        ) == later)
        // 还没有阶段（会话刚建 / 刚从失败态重试）：要记起点，**不能返回 nil** ——
        // 返回 nil 等于这个阶段永远没有起点，进度会停在阶段地板值上。
        #expect(InstallStageTimeline.stageStart(
            entering: .waitingForChannel, currentStage: nil, previous: nil, now: later
        ) == later)
        // 阶段没变、但起点丢了：补上，而不是继续留 nil。
        #expect(InstallStageTimeline.stageStart(
            entering: .signing, currentStage: .signing, previous: nil, now: later
        ) == later)
    }
}
