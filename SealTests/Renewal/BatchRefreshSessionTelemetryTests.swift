import Foundation
import Testing
@testable import Seal

/// 批量续签抽屉的进度 / 计时状态机（2026-09-16 真机反馈「卡在传输那没反应」）。
///
/// 这两个字段决定了抽屉里有没有「活着」的证据：
///   - `currentInstallProgress`：上传阶段的真实百分比，没有它「传输中」就是黑盒；
///   - `installStartedAt`：进入安装阶段的起点，installd 期间没有进度回报，
///     只能靠计时让「还在装」和「卡死」可区分。
///
/// 都是「错了也不崩、只是用户看不到反馈」的字段，所以靠这里钉住。
struct BatchRefreshSessionTelemetryTests {

    @Test
    func recordsUploadProgressOnlyWhilePushing() {
        var session = BatchRefreshSession()
        session.advanceStage(.pushing)
        session.recordInstallProgress(0.42)
        #expect(session.currentInstallProgress == 0.42)

        // 上传完成后 installd 不再回报数值：留下旧百分比会让 UI 显示一个永远不动的数字，
        // 比不显示更糟（用户会以为「传到 42% 就死了」）。
        session.advanceStage(.installing)
        #expect(session.currentInstallProgress == nil)
        session.recordInstallProgress(0.9)
        #expect(session.currentInstallProgress == nil)
    }

    @Test
    func ignoresProgressBeforeThePushingStage() {
        var session = BatchRefreshSession()
        session.advanceStage(.signing)
        session.recordInstallProgress(0.8)
        #expect(session.currentInstallProgress == nil)
    }

    @Test
    func clampsOutOfRangeProgress() {
        var session = BatchRefreshSession()
        session.advanceStage(.pushing)
        session.recordInstallProgress(1.4)
        #expect(session.currentInstallProgress == 1)
        session.recordInstallProgress(-3)
        #expect(session.currentInstallProgress == 0)
    }

    @Test
    func installStartIsRecordedOnceOnEntry() {
        let entered = Date(timeIntervalSince1970: 1_000)
        let repeated = Date(timeIntervalSince1970: 1_040)
        var session = BatchRefreshSession()
        session.advanceStage(.pushing, at: entered)
        #expect(session.installStartedAt == nil)

        session.advanceStage(.installing, at: entered)
        #expect(session.installStartedAt == entered)
        // 同一阶段会被重复推送（签名侧补发 + 安装通道哨兵各一次）：
        // 每次都重置起点会让「已等待」永远停在 0:0x，反而更像卡死。
        session.advanceStage(.installing, at: repeated)
        #expect(session.installStartedAt == entered)
    }

    @Test
    func leavingTheInstallStageClearsTelemetry() {
        var session = BatchRefreshSession()
        session.advanceStage(.pushing, at: Date(timeIntervalSince1970: 1))
        session.recordInstallProgress(0.5)
        session.advanceStage(.installing, at: Date(timeIntervalSince1970: 5))
        session.advanceStage(.verifying, at: Date(timeIntervalSince1970: 9))

        // 不清就会把「上一项已等待 12 分钟」带到下一项，制造不存在的卡死。
        #expect(session.installStartedAt == nil)
        #expect(session.currentInstallProgress == nil)
        #expect(session.currentStage == .verifying)
    }
}
