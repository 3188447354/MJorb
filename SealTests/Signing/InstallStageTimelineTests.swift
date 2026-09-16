import Foundation
import Testing
@testable import Seal

/// 安装阶段计时起点的规则。
///
/// 单签（`AppsViewModel`）与批量续签（`BatchRefreshSession`）共用这一份规则，
/// 因为这条规则错了**不会崩、不会编译失败**，只会让「已等待 m:ss」变成假象：
/// 永远停在 0:00（比不显示更像卡死），或者把上一项的等待时间带到下一项
///（凭空造出「已等待 12 分钟」）。
struct InstallStageTimelineTests {

    @Test
    func firstEntryIntoInstallStageStartsTheClock() {
        let now = Date(timeIntervalSince1970: 500)
        // 上传阶段（.pushing）不是安装阶段：此刻还没有起点。
        #expect(InstallStageTimeline.tick(entering: .installing, currentStage: .pushing) == .restart)
        // 连阶段都还没有时（会话刚建、直接进安装）同样要记起点。
        #expect(InstallStageTimeline.tick(entering: .installing, currentStage: nil) == .restart)
        #expect(InstallStageTimeline.applied(.restart, startedAt: nil, now: now) == now)
    }

    @Test
    func repeatedInstallStageKeepsTheOriginalStart() {
        let start = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 160)
        // 进入安装阶段会被推送不止一次（安装通道的 >1.0 哨兵一次、签名侧补发一次）：
        // 每次都重置起点会让「已等待」永远停在 0:0x。
        #expect(InstallStageTimeline.tick(entering: .installing, currentStage: .installing) == .keep)
        #expect(InstallStageTimeline.applied(.keep, startedAt: start, now: later) == start)
    }

    @Test
    func everyOtherStageClearsTheClock() {
        let start = Date(timeIntervalSince1970: 100)
        for stage in SigningStage.allCases where stage != .installing {
            #expect(InstallStageTimeline.tick(entering: stage, currentStage: .installing) == .clear)
            #expect(InstallStageTimeline.applied(.clear, startedAt: start, now: Date()) == nil)
        }
    }

    @Test
    func keepNeverInventsANewStart() {
        // `.keep` 的语义是「原样保留」：起点本来是 nil 就还是 nil，
        // 不能顺手补一个 now —— 那会让「离开安装阶段后又收到同一阶段推送」
        // 凭空冒出一个计时。
        #expect(InstallStageTimeline.applied(.keep, startedAt: nil, now: Date()) == nil)
    }

    @Test
    func batchSessionFollowsTheSharedRule() {
        // 规则共用之后，批量链路的行为必须与单签完全一致。
        let start = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 1_090)
        var session = BatchRefreshSession()
        session.advanceStage(.installing, at: start)
        #expect(session.installStartedAt == start)
        session.advanceStage(.installing, at: later)
        #expect(session.installStartedAt == start)
        session.advanceStage(.verifying, at: later)
        #expect(session.installStartedAt == nil)
    }
}
