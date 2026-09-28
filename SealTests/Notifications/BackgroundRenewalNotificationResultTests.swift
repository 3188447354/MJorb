import Foundation
import Testing
@testable import Seal

/// 「快捷指令后台续签成功」的系统通知：钉住**该不该发**这条判据。
///
/// 用户要求：只有快捷指令续签成功才发系统通知，Seal 内手动续签不发。
/// 「手动不发」由 `AppsViewModel` 的请求级标记保证（不在本文件的纯判据范围），
/// 这里钉的是「本轮到底值不值得打扰用户」。
struct BackgroundRenewalNotificationResultTests {
    @Test
    func notifiesOnlyWhenSomethingActuallySucceeded() {
        // 全失败：刻意不发 —— 那属于「用户需要处理」，弹通知既不解决问题又会和
        // 「续签成功」这条通知的语义混在一起。
        #expect(
            BackgroundRenewalNotificationResult(total: 3, succeeded: 0, failed: 3, needsAction: 0)
                .shouldNotify == false
        )
        // 一项都没执行：同理不发。
        #expect(
            BackgroundRenewalNotificationResult(total: 3, succeeded: 0, failed: 0, needsAction: 3)
                .shouldNotify == false
        )
        // 没有任何应用：不发。
        #expect(
            BackgroundRenewalNotificationResult(total: 0, succeeded: 0, failed: 0, needsAction: 0)
                .shouldNotify == false
        )
        // 至少一项成功 ⇒ 发。
        #expect(
            BackgroundRenewalNotificationResult(total: 3, succeeded: 1, failed: 2, needsAction: 0)
                .shouldNotify
        )
        #expect(
            BackgroundRenewalNotificationResult(total: 2, succeeded: 2, failed: 0, needsAction: 0)
                .shouldNotify
        )
    }

    @Test
    func fullSuccessReadsAsCompleted() {
        let result = BackgroundRenewalNotificationResult(
            total: 3,
            succeeded: 3,
            failed: 0,
            needsAction: 0
        )
        #expect(result.title == "Seal 续签完成")
        #expect(result.body == "已续签 3/3 个应用（快捷指令后台续签）")
    }

    @Test
    func partialSuccessSpellsOutWhatIsMissing() {
        let result = BackgroundRenewalNotificationResult(
            total: 4,
            succeeded: 2,
            failed: 1,
            needsAction: 1
        )
        #expect(result.title == "Seal 续签部分完成")
        #expect(result.body == "已续签 2/4 个应用，失败 1 个，未执行 1 个（快捷指令后台续签）")
    }

    @Test
    func deliveryStatesAreDistinguishableForLogs() {
        // 真机上「用户说没收到通知」与「其实没给权限」必须能分辨。
        #expect(BackgroundRenewalNotificationDelivery.delivered != .skippedNoSuccess)
        #expect(BackgroundRenewalNotificationDelivery.skippedNotAuthorized != .skippedNoSuccess)
        #expect(BackgroundRenewalNotificationDelivery.failed("-1") != .failed("1"))
    }
}