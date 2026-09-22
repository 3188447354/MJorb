import Foundation
import Testing
@testable import Seal

/// 「待恢复的批量续签结果」载荷 → 队列状态的映射。
///
/// 这条判据的错法**不崩、不编译失败**，只在真机上留下假警报与幽灵条目：
/// 2026-09-17 真机实测 —— Seal 自替换后日志报「1 个应用的结果未知，需要重新核验」，
/// 而结果抽屉同时显示 `succeeded: 2, failed: 0`。所以只能靠单测钉住。
@Suite("待恢复载荷 → 队列状态的映射")
struct PendingBatchResultPayloadTests {
    private func payload(_ items: [[String: Any]]) -> [String: Any] {
        ["succeeded": 2, "failed": 0, "total": 2, "items": items]
    }

    /// Seal 自替换尚未由新进程核验前，绝不能提前结算为成功。
    @Test
    func awaitingSealConfirmationIsNotSettled() {
        let sealID = UUID()
        let states = PendingBatchResultPayload.settledQueueStates(from: payload([
            ["id": sealID.uuidString, "name": "Seal", "isSeal": true, "state": "awaitingSealConfirmation"],
        ]))

        #expect(states[sealID] == nil)
    }

    /// 只收「已定论」的两态。`running` / `waiting` / `preparingSealUpdate` 都没有结论
    /// —— 尤其 `running`：进程就是在这个状态下被杀的。
    @Test
    func onlySettledStatesAreMapped() {
        let completed = UUID()
        let failed = UUID()
        let running = UUID()
        let waiting = UUID()
        let preparing = UUID()
        let states = PendingBatchResultPayload.settledQueueStates(from: payload([
            ["id": completed.uuidString, "name": "A", "state": "completed"],
            ["id": failed.uuidString, "name": "B", "state": "failed"],
            ["id": running.uuidString, "name": "C", "state": "running"],
            ["id": waiting.uuidString, "name": "D", "state": "waiting"],
            ["id": preparing.uuidString, "name": "E", "state": "preparingSealUpdate"],
        ]))

        #expect(states[completed] == .completed)
        #expect(states[failed] == .failed)
        #expect(states[running] == nil)
        #expect(states[waiting] == nil)
        #expect(states[preparing] == nil)
        #expect(states.count == 2)
    }

    /// 空/缺失载荷 ⇒ 空映射（调用方据此退回「一律按未知处理」的保守行为）。
    @Test
    func missingOrEmptyPayloadYieldsNoSettledStates() {
        #expect(PendingBatchResultPayload.settledQueueStates(from: nil).isEmpty)
        #expect(PendingBatchResultPayload.settledQueueStates(from: [:]).isEmpty)
        #expect(PendingBatchResultPayload.settledQueueStates(from: ["items": "not an array"]).isEmpty)
        #expect(PendingBatchResultPayload.settledQueueStates(from: payload([])).isEmpty)
    }

    /// 单条畸形不该毁掉整份映射：其余项照旧能结算。
    @Test
    func malformedItemsAreSkippedWithoutLosingTheRest() {
        let good = UUID()
        let states = PendingBatchResultPayload.settledQueueStates(from: payload([
            ["id": "not-a-uuid", "name": "X", "state": "completed"],
            ["name": "没有 id", "state": "completed"],
            ["id": UUID().uuidString, "name": "没有 state"],
            ["id": good.uuidString, "name": "Y", "state": "failed"],
        ]))

        #expect(states.count == 1)
        #expect(states[good] == .failed)
    }

    /// 同一 app 出现两次时以**后者**为准（写入侧按顺序覆盖，读取侧要一致）。
    @Test
    func laterEntryWinsForTheSameApp() {
        let id = UUID()
        let states = PendingBatchResultPayload.settledQueueStates(from: payload([
            ["id": id.uuidString, "name": "A", "state": "running"],
            ["id": id.uuidString, "name": "A", "state": "completed"],
        ]))

        #expect(states[id] == .completed)
    }

    /// `settledQueueState` 与 `storageValue` 必须互逆（只对已定论的两态）。
    /// 少了一半就会漂移成「写进去是 completed、读出来当未知」。
    @Test
    func settledMappingRoundTripsThroughStorageValue() {
        for state in [BatchRefreshSession.Item.State.completed, .failed] {
            let restored = BatchRefreshSession.Item.State(storageValue: state.storageValue)
            #expect(restored.settledQueueState == state.settledQueueState)
        }
        // 未定论的四态必须都没有 settled 值
        for state in [BatchRefreshSession.Item.State.waiting, .running, .preparingSealUpdate, .awaitingSealConfirmation] {
            #expect(state.settledQueueState == nil)
        }
    }

    @Test
    func newProcessCanSettleOnlyTheAwaitingSealItem() {
        let seal = UUID()
        let other = UUID()
        let original = payload([
            ["id": other.uuidString, "name": "A", "isSeal": false, "state": "completed"],
            ["id": seal.uuidString, "name": "Seal", "isSeal": true, "state": "awaitingSealConfirmation"],
        ])

        let settled = try #require(
            PendingBatchResultPayload.settlingSeal(in: original, to: .completed)
        )
        let items = try #require(settled["items"] as? [[String: Any]])

        #expect(items.first(where: { ($0["id"] as? String) == other.uuidString })?["state"] as? String == "completed")
        #expect(items.first(where: { ($0["id"] as? String) == seal.uuidString })?["state"] as? String == "completed")
        #expect(settled["succeeded"] as? Int == 2)
        #expect(settled["failed"] as? Int == 0)
    }

    @Test
    func failedSelfReplacementIsPersistedAsFailedInsteadOfSuccess() {
        let seal = UUID()
        let original = payload([
            ["id": seal.uuidString, "name": "Seal", "isSeal": true, "state": "awaitingSealConfirmation"],
        ])

        let settled = try #require(
            PendingBatchResultPayload.settlingSeal(in: original, to: .failed)
        )

        #expect(settled["succeeded"] as? Int == 0)
        #expect(settled["failed"] as? Int == 1)
        #expect(PendingBatchResultPayload.settledQueueStates(from: settled)[seal] == .failed)
    }
}
