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

    /// 启动恢复：把上一轮被中断留下的 `running` 项一律降级为 `unknown`。
    ///
    /// 不做这一步，`running` 会永久留在文件里：既不在失败列表（不会被重试），
    /// 也不是 `completed`（不会被清理），用户看到的是一批「永远在跑」的幽灵条目。
    /// 返回被降级的条数，供启动日志与 UI 说明使用。
    @discardableResult
    func recoverInterrupted() throws -> Int {
        var items = try load()
        var recovered = 0
        for index in items.indices where items[index].state == .running {
            items[index].state = .unknown
            recovered += 1
        }
        if recovered > 0 {
            try write(items)
        }
        return recovered
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
