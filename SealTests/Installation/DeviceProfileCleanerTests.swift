import Foundation
import Testing
@testable import Seal

/// 描述文件清理是「最佳努力、永不抛出」，所以**摘要文案是唯一的排障依据**。
///
/// 历史教训：真机上出现过 `描述文件清理：扫描 0，匹配 0，删除 0，中断于 dump，首个错误：NoDevice`
/// —— 一眼看不出「是设备没连上，还是清理逻辑本身坏了」，因为那时摘要里没有「试了几次」。
/// 15 秒正好是 `deviceFetchTimeoutMs`，说明**一次都没重试**就整轮放弃；而同一账号的历史日志里
/// 清理是有成功记录的（`删除 1` / `删除 3`）。也就是说问题不是「清理不可用」，
/// 而是「撞上瞬时不可达就白丢一次机会」—— 下一次机会要等到下次安装或下次启动，
/// profile 在此期间继续累积。
///
/// 这些断言守的是**文案里的信息量**：字段少一个，下次真机排查就退回「一片空白」。
/// 它们也是 `dumpAttempts` 这个字段的存在理由 —— 源码断言只能证明字段被赋值，
/// 只有单测能证明它**真的出现在日志里**。
struct DeviceProfileCleanerTests {

    // MARK: - 默认摘要

    @Test
    func cleanRunStaysShort() {
        let summary = ProfileCleanupSummary(scanned: 12, matched: 2, removed: 2)

        #expect(summary.logMessage == "描述文件清理：扫描 12，匹配 2，删除 2")
    }

    // MARK: - dump 尝试次数（本轮新增的归因依据）

    /// 首次就成功时不写尝试次数：绝大多数清理都是这种，逐条都带「尝试 1 次」只是噪音。
    @Test
    func singleDumpAttemptIsNotMentioned() {
        let summary = ProfileCleanupSummary(scanned: 1, matched: 1, removed: 1, dumpAttempts: 1)

        #expect(summary.logMessage.contains("dump 尝试") == false)
    }

    /// 重试过就必须写出来 —— 这是「设备曾经不可达」的唯一证据。
    @Test
    func retriedDumpIsReported() {
        let summary = ProfileCleanupSummary(scanned: 1, matched: 1, removed: 1, dumpAttempts: 3)

        #expect(summary.logMessage.contains("，dump 尝试 3 次"))
    }

    // MARK: - 失败归因

    /// dump 整轮失败：三样信息缺一不可 —— 断在哪一步、试了几次、首个错误是什么。
    @Test
    func failedDumpKeepsEveryDiagnosticField() {
        var summary = ProfileCleanupSummary()
        summary.stage = "dump"
        summary.firstError = "NoDevice"
        summary.dumpAttempts = 3

        let message = summary.logMessage

        #expect(message.contains("，中断于 dump"), "必须能看出断在哪一步")
        #expect(message.contains("，dump 尝试 3 次"), "必须能看出试了几次 —— 一次不试和试满三次是两种问题")
        #expect(message.contains("，首个错误：NoDevice"), "必须带上底层错误，否则无法区分 NoDevice 与解析失败")
    }

    /// 删除失败与 dump 失败是两回事，各自都要能被看见。
    @Test
    func removalFailuresAreReported() {
        var summary = ProfileCleanupSummary(scanned: 4, matched: 3, removed: 1)
        summary.removeFailed = 2
        summary.firstError = "remove失败: misagent error"

        let message = summary.logMessage

        #expect(message.contains("，删除失败 2"))
        #expect(message.contains("，首个错误：remove失败: misagent error"))
        // 删除阶段失败时 stage 仍是 "done"，不能因此报「中断」—— 那会误导成「整轮没跑完」。
        #expect(message.contains("中断于") == false)
    }

    // MARK: - 跳过路径

    /// 跳过（没有明确「保留哪一份」）也必须留下可读原因：静默跳过 = 用户以为清理坏了。
    @Test
    func skipReasonSurvivesInMessage() {
        let summary = ProfileCleanupSummary(stage: "skipped-no-managed-bundle-ids")

        #expect(summary.logMessage.contains("，中断于 skipped-no-managed-bundle-ids"))
    }
}
