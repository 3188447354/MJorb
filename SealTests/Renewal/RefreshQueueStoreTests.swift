import Foundation
import Testing
@testable import Seal

struct RefreshQueueStoreTests {
    @Test
    func persistsPendingAndCompletedItems() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SealTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RefreshQueueStore(
            fileURL: directory.appending(path: "RefreshQueue.json"),
            fileProtector: MarkerFileProtector()
        )
        let first = RefreshQueueItem(appID: UUID(), accountID: UUID())
        let second = RefreshQueueItem(appID: UUID(), accountID: UUID())

        try await store.replace(with: [first, second])
        try await store.markCompleted(appID: first.appID)
        let reloaded = try await store.load()

        #expect(reloaded.count == 2)
        #expect(reloaded.first(where: { $0.appID == first.appID })?.state == .completed)
        #expect(reloaded.first(where: { $0.appID == second.appID })?.state == .pending)
    }

    @Test
    func clearRemovesCompletedSelfRenewalQueue() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SealTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RefreshQueueStore(
            fileURL: directory.appending(path: "RefreshQueue.json"),
            fileProtector: MarkerFileProtector()
        )
        let completed = RefreshQueueItem(
            appID: UUID(),
            accountID: UUID(),
            state: .completed
        )

        try await store.replace(with: [completed])
        try await store.clear()

        #expect(try await store.load().isEmpty)
    }

    /// 启动恢复的核心：进程在「运行中」被杀留下的 `running` 项必须降级为 `unknown`。
    ///
    /// 不降级的话它会永久停在 `running`：既不在失败列表（不会被重试），
    /// 也不是 `completed`（不会被清理），用户看到的是一批「永远在跑」的幽灵条目。
    @Test
    func recoverInterruptedDowngradesRunningToUnknown() async throws {
        let store = makeStore()
        let interrupted = RefreshQueueItem(appID: UUID(), accountID: UUID(), state: .running)
        let untouched = RefreshQueueItem(appID: UUID(), accountID: UUID(), state: .pending)
        let done = RefreshQueueItem(appID: UUID(), accountID: UUID(), state: .completed)

        try await store.replace(with: [interrupted, untouched, done])
        let recovered = try await store.recoverInterrupted()
        let reloaded = try await store.load()

        #expect(recovered == 1)
        #expect(reloaded.first(where: { $0.appID == interrupted.appID })?.state == .unknown)
        // 非 running 的项一律不许被碰
        #expect(reloaded.first(where: { $0.appID == untouched.appID })?.state == .pending)
        #expect(reloaded.first(where: { $0.appID == done.appID })?.state == .completed)
    }

    @Test
    func recoverInterruptedIsNoOpWhenNothingIsRunning() async throws {
        let store = makeStore()
        try await store.replace(with: [RefreshQueueItem(appID: UUID(), accountID: UUID(), state: .pending)])

        #expect(try await store.recoverInterrupted() == 0)
    }

    /// `outstanding()` 是「只重试失败与未完成项」的落点：已完成的绝不能出现在里面，
    /// 否则恢复流程会重做已经成功的应用（§4 明确要求「恢复不能重做 A」）。
    @Test
    func outstandingExcludesCompletedAndKeepsEverythingElse() async throws {
        let store = makeStore()
        let completed = RefreshQueueItem(appID: UUID(), accountID: UUID(), state: .completed)
        let failed = RefreshQueueItem(appID: UUID(), accountID: UUID(), state: .failed, lastErrorCode: "SEAL-NET-001")
        let unknown = RefreshQueueItem(appID: UUID(), accountID: UUID(), state: .unknown)
        let requiresAction = RefreshQueueItem(
            appID: UUID(),
            accountID: nil,
            state: .requiresAction,
            requiresActionReason: "缺账号"
        )

        try await store.replace(with: [completed, failed, unknown, requiresAction])
        let outstanding = try await store.outstanding()

        #expect(outstanding.contains(where: { $0.appID == completed.appID }) == false)
        #expect(outstanding.count == 3)
        // 持久化顺序必须保持
        #expect(outstanding.map(\.appID) == [failed.appID, unknown.appID, requiresAction.appID])
    }

    /// 从 requiresAction 走出去以后，旧原因不能残留成误导信息。
    @Test
    func requiresActionReasonIsClearedWhenStateMovesOn() async throws {
        let store = makeStore()
        let appID = UUID()
        try await store.replace(with: [RefreshQueueItem(appID: appID, accountID: nil)])

        try await store.markRequiresAction(appID: appID, reason: "缺账号")
        #expect(try await store.load().first?.requiresActionReason == "缺账号")

        try await store.markCompleted(appID: appID)
        let reloaded = try await store.load().first
        #expect(reloaded?.state == .completed)
        #expect(reloaded?.requiresActionReason == nil)
    }

    private func makeStore() -> RefreshQueueStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SealTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return RefreshQueueStore(
            fileURL: directory.appending(path: "RefreshQueue.json"),
            fileProtector: MarkerFileProtector()
        )
    }
}
