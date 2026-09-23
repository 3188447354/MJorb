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

    /// 从持久化条目恢复批量结果。新进程结算 Seal 后必须以条目终态为准，不能继续沿用
    /// 被旧进程写入时的 `awaitingConfirmation` 计数，否则会出现“身份已确认成功、抽屉仍在等待”的假象。
    static func restoredResult(from payload: [String: Any]) -> BatchRefreshResult {
        let items = payload[Key.items] as? [[String: Any]] ?? []
        let total = max(payload["total"] as? Int ?? 0, items.count)
        guard items.isEmpty == false else {
            let succeeded = payload["succeeded"] as? Int ?? 0
            let failed = payload["failed"] as? Int ?? 0
            return BatchRefreshResult(
                total: total,
                succeeded: succeeded,
                failed: failed,
                needsAction: max(0, total - succeeded - failed),
                awaitingConfirmation: 0
            )
        }

        let states = items.map { BatchRefreshSession.Item.State(storageValue: $0[Key.state] as? String) }
        let succeeded = states.filter { $0 == .completed }.count
        let failed = states.filter { $0 == .failed }.count
        let awaitingConfirmation = states.filter { $0 == .awaitingSealConfirmation }.count
        return BatchRefreshResult(
            total: total,
            succeeded: succeeded,
            failed: failed,
            needsAction: max(0, total - succeeded - failed - awaitingConfirmation),
            awaitingConfirmation: awaitingConfirmation
        )
    }

    /// 返回可稳定比较的载荷指纹，供界面识别「已恢复过一次」与「新进程刚写回结算」的区别。
    ///
    /// 不能只依赖时间戳：历史载荷不一定含时间戳，而条目终态才是决定抽屉分桶的真实来源。
    static func restorationFingerprint(from payload: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        return data.base64EncodedString()
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
