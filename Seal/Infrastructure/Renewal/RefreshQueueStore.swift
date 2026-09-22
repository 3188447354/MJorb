import Foundation

actor RefreshQueueStore {
    private let fileURL: URL
    private let fileProtector: any FileProtecting
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        fileURL: URL,
        fileProtector: any FileProtecting = CompleteFileProtector()
    ) {
        self.fileURL = fileURL
        self.fileProtector = fileProtector
        encoder.outputFormatting = [.sortedKeys]
    }

    func load() throws -> [RefreshQueueItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try decoder.decode(
            [RefreshQueueItem].self,
            from: Data(contentsOf: fileURL)
        )
    }

    func replace(with items: [RefreshQueueItem]) throws {
        try write(items)
    }

    func markRunning(appID: UUID) throws {
        try update(appID: appID, state: .running, errorCode: nil)
    }

    func markCompleted(appID: UUID) throws {
        try update(appID: appID, state: .completed, errorCode: nil)
    }

    func markFailed(appID: UUID, errorCode: String) throws {
        try update(appID: appID, state: .failed, errorCode: errorCode)
    }

    func markPending(appID: UUID) throws {
        try update(appID: appID, state: .pending, errorCode: nil)
    }

    /// 结果未知（进程在运行中被杀）。既不是成功也不是失败，必须保留到核验为止。
    func markUnknown(appID: UUID) throws {
        try update(appID: appID, state: .unknown, errorCode: nil)
    }

    /// 本轮不执行，等用户先处理前置条件（例如缺可用账号）。
    func markRequiresAction(appID: UUID, reason: String) throws {
        try update(
            appID: appID,
            state: .requiresAction,
            errorCode: nil,
            requiresActionReason: reason
        )
    }

    /// 启动恢复：把上一轮被中断留下的 `running` 项降级为 `unknown`。
    ///
    /// 不做这一步，`running` 会永久留在文件里：既不在失败列表（不会被重试），
    /// 也不是 `completed`（不会被清理），用户看到的是一批「永远在跑」的幽灵条目。
    ///
    /// ## ⚠️ 有**已定论**的结果时不许降级（2026-09-17 真机实测）
    ///
    /// Seal **自己替换自己**时，进程必然在队列项还是 `running` 的时候被杀。新进程
    /// 只有在读取真实运行包身份后，才会把那一项的终态写进持久化载荷。若队列恢复早于
    /// 核验，它可能已经被降级为 `unknown`，因此已知终态同样必须能覆盖 `unknown`。
    ///
    /// - 日志报「1 个应用的结果未知，需要重新核验」（假警报）
    /// - 队列文件里留下一个幽灵条目
    /// - 而结果抽屉同时显示 `succeeded: 2, failed: 0`
    ///
    /// ⇒ 传入 `settled` 的项按**已知结论**结算，只有真正没有结论的 `running` 项才降级为 `unknown`。
    ///
    /// - Parameter settled: 已经从持久化载荷拿到结论的项（appID → 状态）。
    @discardableResult
    func recoverInterrupted(settled: [UUID: RefreshQueueItem.State] = [:]) throws -> RecoveryOutcome {
        var items = try load()
        var outcome = RecoveryOutcome()
        for index in items.indices where items[index].state == .running || items[index].state == .unknown {
            if let known = settled[items[index].appID] {
                items[index].state = known
                outcome.settledFromResult += 1
            } else if items[index].state == .running {
                items[index].state = .unknown
                outcome.downgraded += 1
            }
        }
        if outcome.changedAnything {
            try write(items)
        }
        return outcome
    }

    /// 启动恢复的结果 —— 两个数分开记，因为它们对应**完全不同的后续动作**：
    /// `downgraded > 0` 要提示用户「需要重新核验」；`settledFromResult > 0` 只是说明
    /// 「被中断的那一轮其实有结果，已按结果结算」，属于正常路径。
    struct RecoveryOutcome: Equatable, Sendable {
        /// 降级为「结果未知」的条数（真的没有结论）。
        var downgraded = 0
        /// 按持久化结果**结算**（而不是当未知）的条数。
        var settledFromResult = 0

        var changedAnything: Bool { downgraded > 0 || settledFromResult > 0 }
    }

    /// 本轮结束后仍需处理的项（失败 / 未执行 / 结果未知），保持持久化顺序。
    func outstanding() throws -> [RefreshQueueItem] {
        try load().filter(\.needsFollowUp)
    }

    func removeCompleted() throws {
        try write(try load().filter { $0.state != .completed })
    }

    func clear() throws {
        try write([])
    }

    private func update(
        appID: UUID,
        state: RefreshQueueItem.State,
        errorCode: String?,
        requiresActionReason: String? = nil
    ) throws {
        var items = try load()
        guard let index = items.firstIndex(where: { $0.appID == appID }) else { return }
        items[index].state = state
        items[index].lastErrorCode = errorCode
        // 状态一变就重写原因：从 requiresAction 走出去以后，旧原因不能残留成误导信息。
        items[index].requiresActionReason = requiresActionReason
        try write(items)
    }

    private func write(_ items: [RefreshQueueItem]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try encoder.encode(items).write(to: fileURL, options: .atomic)
        try fileProtector.protect(fileURL)
    }
}
