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

    // MARK: - 旧 Team 变体的回收（换 Apple ID 后堆积的那一批）

    /// 没有候选时一个多余的字都不写 —— 绝大多数清理都走这条路，加前缀只是噪音。
    @Test
    func noReclaimTextWhenThereAreNoCandidates() {
        let summary = ProfileCleanupSummary(scanned: 9, matched: 3, removed: 1)

        #expect(summary.logMessage.contains("旧 Team 变体") == false)
        #expect(summary.logMessage.contains("回收中止") == false)
    }

    /// 有候选就必须四个数都在：**只看「回收 0」分不清**
    /// 「形态没匹配上」/「设备上确实还装着」/「核验查不通」—— 三者的后续动作完全不同。
    @Test
    func reclaimCountsAreAllReported() {
        var summary = ProfileCleanupSummary(scanned: 40, matched: 20, removed: 3)
        summary.reclaimCandidates = 18
        summary.reclaimed = 7
        summary.reclaimKeptInstalled = 9
        summary.reclaimUnverified = 1
        summary.reclaimSample = ["com.kdt.livecontainer.seal.3432ZHJUF9"]

        let message = summary.logMessage

        #expect(message.contains("；旧 Team 变体：候选 18，回收 7"))
        #expect(message.contains("，已装保留 9"))
        #expect(message.contains("，未能核验 1"))
        #expect(message.contains("，示例 com.kdt.livecontainer.seal.3432ZHJUF9"))
    }

    /// 候选多于样本上限时要带「等」，否则会让人以为候选总共就这几个。
    @Test
    func sampleIsTruncatedWithSuffix() {
        var summary = ProfileCleanupSummary()
        summary.reclaimCandidates = 30
        summary.reclaimSample = (1...ProfileCleanupSummary.reclaimSampleLimit).map { "com.x\($0).seal.T" }

        #expect(summary.logMessage.contains(" 等"))
    }

    /// **受保护集合的规模**必须进日志 —— 它是「候选为什么这么多」的第一归因。
    ///
    /// 2026-09-17 真机（构建 97）的日志里只有 `候选 4，回收 3`，看不出那一刻
    /// 受保护集合里到底有没有那个 App 的 ID；事后只能靠推断。
    /// 有了这个数，下次一眼就能分辨「设备上真有这么多孤儿」与「记录没读全」。
    @Test
    func protectedSetSizeIsReported() {
        var summary = ProfileCleanupSummary()
        summary.reclaimCandidates = 4
        summary.protectedCount = 7

        #expect(summary.logMessage.contains("，受保护 7"))
    }

    /// 因「父 App 已装」而保留的扩展要单独计数，**不能**混进 `已装保留` ——
    /// 那条是「这个 Bundle ID 自己装着」，这条是「它自己是扩展、装不了，但父 App 装着」。
    /// 归因不同，排查时该看的下一处也不同。
    @Test
    func extensionKeptCountIsReportedSeparately() {
        var summary = ProfileCleanupSummary()
        summary.reclaimCandidates = 4
        summary.reclaimed = 1
        summary.reclaimKeptInstalled = 1
        summary.reclaimKeptExtension = 2

        let message = summary.logMessage

        #expect(message.contains("，已装保留 1"))
        #expect(message.contains("，扩展随父保留 2"))
    }

    /// 没有扩展被保留时不写这一段 —— 绝大多数清理都不需要，加了只是噪音。
    @Test
    func extensionKeptTextIsOmittedWhenZero() {
        var summary = ProfileCleanupSummary()
        summary.reclaimCandidates = 3
        summary.reclaimed = 3

        #expect(summary.logMessage.contains("扩展随父保留") == false)
    }

    /// 中止必须显眼，且**不能被误读成「整轮清理失败」**：
    /// 路径 1（保留集合内去重）的结果仍然有效，所以不能借用 `中断于`。
    @Test
    func reclaimAbortIsVisibleWithoutClaimingTheWholeRunFailed() {
        var summary = ProfileCleanupSummary(scanned: 30, matched: 12, removed: 2)
        summary.reclaimCandidates = 17
        summary.reclaimAborted = "阳性对照未通过（com.mjorb.seal.TB95F327DS 被答成未安装）"

        let message = summary.logMessage

        #expect(message.contains("，回收中止：阳性对照未通过"))
        #expect(message.contains("删除 2"), "路径 1 的成绩必须留着 —— 中止的只是回收")
        #expect(message.contains("中断于") == false, "回收中止不是整轮中断，借用这个词会让人以为清理白跑了")
    }

    // MARK: - dump 失败也要带出真实尝试次数（2026-09-24）

    /// 只为承载「底层错误」而存在的占位错误。
    ///
    /// **刻意不用 `MinimuxerError.NoDevice`**：`SealTests` 的依赖只有 `Seal` 与
    /// `ZIPFoundation`（`project.yml`），**没有 Minimuxer** ⇒ 在这里 `import Minimuxer`
    /// 只会在 `swift-regression` 上炸（`build-package` 不编译测试 target，照绿）。
    /// 本仓已有测试也一律不 import 它。
    private struct StubDumpError: Error, CustomStringConvertible {
        var description: String { "NoDevice" }
    }

    /// `DumpProfilesFailure` 必须把「试了几次」带出来。
    ///
    /// 失败分支原来提前 `return`（`summary.dumpAttempts = dump.attempts` 写在 `do` 之后），
    /// 于是 `dumpAttempts` 停在默认值 1 ⇒ 日志里「重试 3 次仍失败」看起来和
    /// 「一次都没试」一模一样，而两者的下一步动作完全不同（查重试有没有生效 vs 查隧道）。
    @Test
    func dumpFailureCarriesAttemptCount() {
        let failure = DumpProfilesFailure(attempts: 3, underlying: StubDumpError())

        #expect(failure.attempts == 3)
    }

    /// 端到端的那一步：调用方从错误里取出次数后，摘要要能把它写进日志。
    ///
    /// 源码断言只能证明「有人赋了值」；只有这里能证明它**真的出现在日志里**。
    @Test
    func failedDumpLogsTheAttemptCountFromTheError() {
        let failure = DumpProfilesFailure(attempts: 3, underlying: StubDumpError())
        var summary = ProfileCleanupSummary()
        summary.stage = "dump"
        summary.dumpAttempts = failure.attempts
        summary.firstError = String(describing: failure.underlying)

        #expect(summary.logMessage.contains("，dump 尝试 3 次"))
        #expect(summary.logMessage.contains("，中断于 dump"))
    }
}
