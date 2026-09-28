import Foundation
import Testing
@testable import Seal

/// 「快捷指令后台续签」结束后的系统通知：钉住**该不该发**与**说什么**。
///
/// 用户要求：只有快捷指令那条链路发通知，Seal 内手动续签不发。
/// 「手动不发」由 `AppsViewModel` 的请求级标记保证（不在本文件的纯判据范围），
/// 这里钉的是「本轮到底值不值得打扰用户」以及四桶怎么落到文案上。
struct BackgroundRenewalNotificationResultTests {
    private func make(
        total: Int,
        succeeded: Int,
        failed: Int = 0,
        needsAction: Int = 0,
        awaitingConfirmation: Int = 0
    ) -> BackgroundRenewalNotificationResult {
        BackgroundRenewalNotificationResult(
            total: total,
            succeeded: succeeded,
            failed: failed,
            needsAction: needsAction,
            awaitingConfirmation: awaitingConfirmation
        )
    }

    /// 有项要续签就发 —— **全失败更要发**。
    ///
    /// 🔴 这条判据在 2026-09-28 被真机日志推翻过一次：原实现只在 `succeeded > 0` 时发，
    /// 于是 18:41:38 那轮「共 3，成功 0，失败 3」只留下「按规则不发」⇒ 用户什么都收不到。
    @Test
    func notifiesWheneverThereIsSomethingToRenew() {
        #expect(make(total: 3, succeeded: 3).shouldNotify)
        #expect(make(total: 3, succeeded: 1, failed: 2).shouldNotify)
        // 全失败：**必须发**（静默失败会让用户在应用过期那天才发现）。
        #expect(make(total: 3, succeeded: 0, failed: 3).shouldNotify)
        // 一项都没执行 / 全在待核验：也要发，否则用户以为整轮成功了。
        #expect(make(total: 3, succeeded: 0, needsAction: 3).shouldNotify)
        #expect(make(total: 3, succeeded: 0, awaitingConfirmation: 3).shouldNotify)
        // 没有任何需要续签的项：不发 —— 弹「已续签 0/0」是纯噪音。
        #expect(make(total: 0, succeeded: 0).shouldNotify == false)
    }

    @Test
    func fullSuccessReadsAsCompleted() {
        let result = make(total: 3, succeeded: 3)
        #expect(result.title == "Seal 续签完成")
        #expect(result.body == "已续签 3/3 个应用（快捷指令后台续签）")
    }

    @Test
    func partialFailureIsCalledOutAsFailure() {
        let result = make(total: 3, succeeded: 1, failed: 2)
        #expect(result.title == "Seal 续签部分失败")
        #expect(result.body == "已续签 1/3 个应用，失败 2 个（快捷指令后台续签）")
    }

    @Test
    func totalFailureIsCalledOutAsFailure() {
        let result = make(total: 3, succeeded: 0, failed: 3)
        #expect(result.title == "Seal 续签失败")
        #expect(result.body == "已续签 0/3 个应用，失败 3 个（快捷指令后台续签）")
    }

    /// 没有失败、但有未执行 / 待核验：不能叫「失败」（`needsAction` 是「没试」，
    /// 说失败会误导 —— 与 `RenewalCoordinator.emitFailure` 的口径一致）。
    @Test
    func noFailuresButSomethingMissingIsPartialCompletion() {
        let result = make(total: 4, succeeded: 2, needsAction: 1, awaitingConfirmation: 1)
        #expect(result.title == "Seal 续签部分完成")
        #expect(
            result.body == "已续签 2/4 个应用，未执行 1 个，待核验 1 个（快捷指令后台续签）"
        )
    }

    /// 零成功、零失败（全未执行 / 全待核验）：说「部分完成」会误导 ⇒ 用「未完成」。
    @Test
    func nothingSucceededAndNothingFailedReadsAsIncomplete() {
        let result = make(total: 2, succeeded: 0, needsAction: 1, awaitingConfirmation: 1)
        #expect(result.title == "Seal 续签未完成")
        #expect(
            result.body == "已续签 0/2 个应用，未执行 1 个，待核验 1 个（快捷指令后台续签）"
        )
    }

    /// `awaitingConfirmation` 曾经**根本没被带进通知** ⇒ 正文看不出那几项是「待核验」。
    @Test
    func awaitingConfirmationIsSpelledOutInBody() {
        let result = make(total: 3, succeeded: 1, awaitingConfirmation: 2)
        #expect(result.body.contains("待核验 2 个"))
    }

    /// 「本轮没跑起来」的三档：让位给非续签操作 / 等锁超时 ⇒ 未执行；整轮抛错 ⇒ 失败。
    @Test
    func skippedNoticeCoversTheThreeSilentExits() {
        let blocked = BackgroundRenewalSkippedNotice(
            reason: .blockedByOtherOperation("「导入配对文件」")
        )
        #expect(blocked.title == "Seal 续签未执行")
        #expect(blocked.body.contains("「导入配对文件」"))

        let timedOut = BackgroundRenewalSkippedNotice(
            reason: .operationLockTimeout("「管理证书」")
        )
        #expect(timedOut.title == "Seal 续签未执行")
        #expect(timedOut.body.contains("「管理证书」"))

        let roundFailed = BackgroundRenewalSkippedNotice(reason: .roundFailed(title: "无法续签应用"))
        #expect(roundFailed.title == "Seal 续签失败")
        #expect(roundFailed.body.contains("无法续签应用"))
    }

    @Test
    func deliveryStatesAreDistinguishableForLogs() {
        // 真机上「用户说没收到通知」与「其实没给权限」必须能分辨。
        #expect(BackgroundRenewalNotificationDelivery.delivered != .skippedNothingToRenew)
        #expect(BackgroundRenewalNotificationDelivery.skippedNotAuthorized != .skippedNothingToRenew)
        #expect(BackgroundRenewalNotificationDelivery.failed("-1") != .failed("1"))
    }
}