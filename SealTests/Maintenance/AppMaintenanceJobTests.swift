import Foundation
import Testing
@testable import Seal

/// 维护作业的关键约束：
/// 1. 非空闲 ⇒ 完全不动（不写、不删）。
/// 2. 只在 DB 无引用时删目录；事务中间态与新建目录绝不删。
/// 3. 检查点一旦失效 ⇒ 立刻退出，且**不得进入删除步骤**。
@MainActor
struct AppMaintenanceJobTests {

    // MARK: - 非空闲 ⇒ 一个文件都不动

    @Test
    func skipsWithoutTouchingFilesWhenForegroundOperationIsActive() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = OperationCoordinator()
        let orphan = try makeAppDirectory(fixture, appID: UUID(), backdated: true)
        let foreground = try #require(coordinator.begin(.installing))
        defer { coordinator.end(foreground) }

        let job = makeJob(fixture, gate: MaintenanceGate(coordinator: coordinator))
        let outcome = await job.run()

        #expect(outcome == .skipped)
        #expect(FileManager.default.fileExists(atPath: orphan.path), "跳过时必须一个文件都不动")
    }

    // MARK: - 孤儿目录：只删 DB 无引用的

    @Test
    func removesOrphanDirectoryButKeepsRecordedOnes() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let keptID = UUID()
        let kept = try makeAppDirectory(fixture, appID: keptID, backdated: true)
        let orphan = try makeAppDirectory(fixture, appID: UUID(), backdated: true)
        let store = InMemoryAppStore(records: [makeRecord(appID: keptID)])

        let job = makeJob(fixture, store: store)
        let outcome = await job.run()

        let report = try #require(completedReport(outcome))
        #expect(report.removedAppDirectories == 1)
        #expect(FileManager.default.fileExists(atPath: orphan.path) == false)
        #expect(FileManager.default.fileExists(atPath: kept.path), "DB 里有记录的应用目录不能删")
    }

    // MARK: - 事务中间态（这是一条真实的数据丢失路径）

    @Test
    func keepsInFlightImportTransactionDirectory() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transactionID = UUID()
        let pending = try makeTransactionDirectory(
            fixture, appID: UUID(), transactionID: transactionID, kind: "pending", backdated: true
        )
        try writeImportJournal(fixture, transactionID: transactionID)

        let job = makeJob(fixture)
        let outcome = await job.run()

        let report = try #require(completedReport(outcome))
        #expect(report.skippedInFlightTransactions == 1)
        #expect(report.removedTransactionDirectories == 0)
        #expect(
            FileManager.default.fileExists(atPath: pending.path),
            "journal 还在 ⇒ 导入事务未结束，删它的中间目录会让导入失败并可能丢数据"
        )
    }

    @Test
    func removesTransactionDirectoryWhenJournalIsGone() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let backup = try makeTransactionDirectory(
            fixture, appID: UUID(), transactionID: UUID(), kind: "backup", backdated: true
        )

        let job = makeJob(fixture)
        let outcome = await job.run()

        let report = try #require(completedReport(outcome))
        #expect(report.removedTransactionDirectories == 1)
        #expect(FileManager.default.fileExists(atPath: backup.path) == false, "journal 已消失 ⇒ 是残留")
    }

    // MARK: - 新建保护期（与前台操作抢时序的兜底）

    @Test
    func protectsRecentlyCreatedDirectories() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fresh = try makeAppDirectory(fixture, appID: UUID(), backdated: false)

        let job = makeJob(fixture)
        let outcome = await job.run()

        let report = try #require(completedReport(outcome))
        #expect(report.skippedRecent == 1)
        #expect(report.removedAppDirectories == 0)
        #expect(FileManager.default.fileExists(atPath: fresh.path), "刚创建的目录可能属于进行中的导入，不能删")
    }

    // MARK: - 检查点失效 ⇒ 不得进入删除步骤

    @Test
    func abortsBeforeSweepingWhenLeaseIsInvalidated() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let orphan = try makeAppDirectory(fixture, appID: UUID(), backdated: true)

        // 第一次检查点就返回失效 —— 模拟「作业刚开始，用户就点了签名」
        let job = makeJob(fixture, gate: AbortOnCheckpointGate(abortFromCheck: 1))
        let outcome = await job.run()

        guard case .aborted(let stage, _) = outcome else {
            Issue.record("检查点失效时应当中断，实际：\(outcome)")
            return
        }
        #expect(stage == "孤儿文件清理")
        #expect(FileManager.default.fileExists(atPath: orphan.path), "被打断后一步删除都不能做")
    }

    @Test
    func abortsRightAfterRecoveryWhenForegroundOperationStarts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let orphan = try makeAppDirectory(fixture, appID: UUID(), backdated: true)
        let recovery = AppRecordRecovery(appStore: InMemoryAppStore(), fileStore: fixture.fileStore)

        let job = makeJob(
            fixture,
            gate: AbortOnCheckpointGate(abortFromCheck: 1),
            recovery: recovery
        )
        let outcome = await job.run()

        guard case .aborted(let stage, _) = outcome else {
            Issue.record("检查点失效时应当中断，实际：\(outcome)")
            return
        }
        #expect(stage == "记录恢复")
        #expect(FileManager.default.fileExists(atPath: orphan.path), "恢复后被打断 ⇒ 不得进入删除步骤")
    }

    @Test
    func completesWhenCheckpointsStayValid() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recovery = AppRecordRecovery(appStore: InMemoryAppStore(), fileStore: fixture.fileStore)

        let job = makeJob(fixture, gate: AbortOnCheckpointGate(abortFromCheck: .max), recovery: recovery)
        let outcome = await job.run()

        guard case .completed = outcome else {
            Issue.record("检查点始终有效时应当完成，实际：\(outcome)")
            return
        }
    }

    // MARK: - 夹具

    private struct Fixture {
        let root: URL
        let documents: URL
        let fileStore: AppFileStore
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SealMaintenanceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let cache = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return Fixture(
            root: root,
            documents: documents,
            fileStore: AppFileStore(
                documentsDirectory: documents,
                cacheDirectory: cache,
                fileProtector: MarkerFileProtector()
            )
        )
    }

    private func appsRoot(_ fixture: Fixture) -> URL {
        fixture.documents.appending(path: "Apps", directoryHint: .isDirectory)
    }

    private func makeAppDirectory(_ fixture: Fixture, appID: UUID, backdated: Bool) throws -> URL {
        let directory = appsRoot(fixture).appending(path: appID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("ipa".utf8).write(to: directory.appending(path: "Original.ipa"))
        try backdateIfNeeded(directory, backdated: backdated)
        return directory
    }

    private func makeTransactionDirectory(
        _ fixture: Fixture,
        appID: UUID,
        transactionID: UUID,
        kind: String,
        backdated: Bool
    ) throws -> URL {
        let name = ".\(appID.uuidString).\(kind)-\(transactionID.uuidString)"
        let directory = appsRoot(fixture).appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("ipa".utf8).write(to: directory.appending(path: "Original.ipa"))
        try backdateIfNeeded(directory, backdated: backdated)
        return directory
    }

    private func writeImportJournal(_ fixture: Fixture, transactionID: UUID) throws {
        let directory = fixture.documents.appending(path: "Transactions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // liveImportTransactionIDs() 只读文件名、不解析内容，因此不需要构造完整事务对象。
        try Data("{}".utf8).write(to: directory.appending(path: "import-\(transactionID.uuidString).json"))
    }

    private func backdateIfNeeded(_ url: URL, backdated: Bool) throws {
        guard backdated else { return }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7200)],
            ofItemAtPath: url.path
        )
    }

    private func makeRecord(appID: UUID) -> AppRecord {
        AppRecord(
            id: appID,
            originalBundleIdentifier: "com.seal.maintenance.\(appID.uuidString.prefix(8))",
            name: "维护测试应用",
            version: "1.0.0",
            buildNumber: "1",
            size: 1024,
            state: .imported,
            ipaRelativePath: "Apps/\(appID.uuidString)/Original.ipa",
            importedAt: Date()
        )
    }

    private func makeJob(
        _ fixture: Fixture,
        gate: (any MaintenanceLeasing)? = nil,
        store: InMemoryAppStore = InMemoryAppStore(),
        recovery: AppRecordRecovery? = nil
    ) -> AppMaintenanceJob {
        AppMaintenanceJob(
            // 默认闸门「永不失效」，用来测正常路径
            gate: gate ?? AbortOnCheckpointGate(abortFromCheck: .max),
            appStore: store,
            fileStore: fixture.fileStore,
            recovery: recovery,
            selfAppRegistrar: nil,
            logStore: nil
        )
    }

    private func completedReport(_ outcome: AppMaintenanceJob.Outcome) -> OrphanSweepReport? {
        guard case .completed(let report) = outcome else {
            Issue.record("应当正常完成，实际：\(outcome)")
            return nil
        }
        return report
    }
}

/// 第 N 次检查点开始返回「失效」，用来确定性地复现
/// 「用户操作恰好在维护作业中途开始」—— 靠计时或并发调度做不出稳定复现。
@MainActor
private final class AbortOnCheckpointGate: MaintenanceLeasing {
    private let abortFromCheck: Int
    private var checks = 0
    private var token: UUID?

    init(abortFromCheck: Int) {
        self.abortFromCheck = abortFromCheck
    }

    func tryAcquire() -> UUID? {
        let token = UUID()
        self.token = token
        return token
    }

    func end(_ token: UUID) {
        self.token = nil
    }

    func shouldAbort(_ token: UUID) -> Bool {
        checks += 1
        return checks >= abortFromCheck
    }
}
