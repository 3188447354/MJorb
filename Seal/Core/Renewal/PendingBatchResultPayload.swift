import Foundation

/// 「待恢复的批量续签结果」载荷 → 续签队列状态的映射。
///
/// ## 为什么单独成一个类型
///
/// 这条判据的错法是「**不崩、不编译失败，只在真机上留下假警报与幽灵条目**」
/// （2026-09-17 真机实测：Seal 自替换后日志报「1 个应用的结果未知，需要重新核验」，
/// 而结果抽屉同时显示 `succeeded: 2, failed: 0`）。
/// 源码断言证明不了它，只能靠单测 —— 所以判据要从 `AppsViewModel`
/// （`@MainActor`、依赖一大堆、测试构造不出来）里挪出来。
///
/// 载荷的字段名与 `AppsViewModel.persistPendingBatchResult` 一一对应，
/// 两处改动必须同时做（守卫断言这两个文件里都出现同一组键名）。
enum PendingBatchResultPayload {
    /// 载荷里每项的键名 —— 与写入侧共用同一组字面量，避免「改了一边忘了另一边」。
    enum Key {
        static let items = "items"
        static let id = "id"
        static let state = "state"
    }

    /// 取出载荷里**已经有结论**的项（appID → 队列状态）。
    ///
    /// 只收「已定论」的两态；`waiting` / `running` / `preparingSealUpdate` 都没有结论
    /// （`running` 尤其：进程就是在这个状态下被杀的），交给队列恢复按「结果未知」处理。
    ///
    /// - Parameter payload: `loadPendingBatchResultPayload()` 读出来的原始载荷；可为空。
    static func settledQueueStates(from payload: [String: Any]?) -> [UUID: RefreshQueueItem.State] {
        guard let items = payload?[Key.items] as? [[String: Any]] else { return [:] }
        var states: [UUID: RefreshQueueItem.State] = [:]
        for item in items {
            guard let idString = item[Key.id] as? String,
                  let id = UUID(uuidString: idString),
                  let settled = BatchRefreshSession.Item.State(storageValue: item[Key.state] as? String)
                      .settledQueueState else { continue }
            states[id] = settled
        }
        return states
    }

    /// 新进程完成 Seal 自替换身份核验后，才允许为那一项写入终态。
    ///
    /// 只结算明确处于 `awaitingSealConfirmation` 的 Seal 项，避免启动时把旧载荷里
    /// 已完成/正在运行的无关项误改写。计数从条目重新计算，杜绝旧进程的乐观计数残留。
    static func settlingSeal(
        in payload: [String: Any],
        to state: BatchRefreshSession.Item.State
    ) -> [String: Any]? {
        guard state == .completed || state == .failed,
              var items = payload[Key.items] as? [[String: Any]] else { return nil }

        var changed = false
        for index in items.indices {
            let isSeal = items[index]["isSeal"] as? Bool ?? false
            let itemState = BatchRefreshSession.Item.State(storageValue: items[index][Key.state] as? String)
            guard isSeal, itemState == .awaitingSealConfirmation else { continue }
            items[index][Key.state] = state.storageValue
            changed = true
        }
        guard changed else { return nil }

        var updated = payload
        updated[Key.items] = items
        updated["succeeded"] = items.filter {
            BatchRefreshSession.Item.State(storageValue: $0[Key.state] as? String) == .completed
        }.count
        updated["failed"] = items.filter {
            BatchRefreshSession.Item.State(storageValue: $0[Key.state] as? String) == .failed
        }.count
        updated["total"] = max(payload["total"] as? Int ?? 0, items.count)
        updated["timestamp"] = Date().timeIntervalSince1970
        return updated
    }
}
