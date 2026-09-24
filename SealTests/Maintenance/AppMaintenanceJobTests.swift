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

    // MARK: - 设备端旧描述文件清理（第 4 步）

    @Test
    func sweepsOnlyBundleIdentifiersWithARecordedProfileUUID() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let known = UUID()
        let unknown = UUID()
        let store = InMemoryAppStore(records: [
            makeRecord(
                appID: known,
                mappedBundleIdentifier: "com.example.known",
                provisioningProfileUUID: "AAAA-BBBB"
            ),
            // 没有记录 profile UUID：必须整条跳过，不能猜「保留最新那份」
            makeRecord(appID: unknown, mappedBundleIdentifier: "com.example.unknown"),
        ])
        let sweeper = RecordingProfileSweeper()

        let job = makeJob(fixture, store: store, profileSweeper: sweeper)
        let outcome = await job.run()

        guard case .completed(let report) = outcome else {
            Issue.record("应当正常完成，实际：\(outcome)")
            return
        }
        #expect(report.profiles.stage == "done")
        let maps = await sweeper.receivedKeepMaps
        #expect(maps.count == 1)
        #expect(maps.first == ["com.example.known": "AAAA-BBBB"])
    }

    /// 维护作业必须**开启**孤儿回收。
    ///
    /// 这是个 Bool 开关，漏传（或将来被改成默认 `false` 而调用方没显式传）时
    /// 编译不会失败、单测也不会红 —— 只会让「换 Apple ID 后旧 Team 后缀的 profile」
    /// 永远清不掉，而这正是用户报的那个现象。所以必须钉住。
    @Test
    func maintenanceSweepEnablesSealOrphanReclaim() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = InMemoryAppStore(records: [
            makeRecord(
                appID: UUID(),
                mappedBundleIdentifier: "com.example.known",
                provisioningProfileUUID: "AAAA-BBBB"
            )
        ])
        let sweeper = RecordingProfileSweeper()

        let job = makeJob(fixture, store: store, profileSweeper: sweeper)
        _ = await job.run()

        let flags = await sweeper.receivedReclaimFlags
        #expect(flags == [true])
    }

    @Test
    /// 扩展 ID 必须进**宽松**受保护集合，**不**受 `signedArtifactStatus` 门槛影响。
    ///
    /// 严格 keep-map 只在 `signedArtifactStatus == .installed` 时才收扩展（那个取舍本身对：
    /// 安装失败时扩展记录指向设备上并不存在的 profile，拿它当保留集合会把真在用的删掉）。
    /// 但那个标记一旦陈旧，扩展 ID 就掉出**保护范围** ⇒ 变成回收候选，
    /// 而扩展的设备端核验（`isAppInstalled`）恒为「没装」⇒ 删掉正在用的扩展 profile。
    /// 2026-09-17 真机（构建 95）就是这么丢掉 LiveContainer 三个扩展的：
    /// `候选 4，回收 3，已装保留 1`，主 App 被设备核验救下、三个扩展全删。
    func protectedSetCoversExtensionsEvenWhenRecordIsNotMarkedInstalled() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mainID = "com.example.seal.TEAMID"
        let extensionID = "com.example.seal.TEAMID.ShareExtension"
        let store = InMemoryAppStore(records: [
            makeRecord(
                appID: UUID(),
                mappedBundleIdentifier: mainID,
                provisioningProfileUUID: "AAAA-BBBB",
                // 刻意**不**是 `.installed` —— 真机上记录陈旧的形态就是这种。
                signedArtifactStatus: .available,
                extensions: [
                    AppExtensionRecord(
                        name: "ShareExtension",
                        originalBundleIdentifier: "com.example.ShareExtension",
                        mappedBundleIdentifier: extensionID,
                        provisioningProfileUUID: "CCCC-DDDD"
                    )
                ]
            )
        ])
        let sweeper = RecordingProfileSweeper()

        let job = makeJob(fixture, store: store, profileSweeper: sweeper)
        _ = await job.run()

        let keepMaps = await sweeper.receivedKeepMaps
        let protectedSets = await sweeper.receivedProtectedSets
        #expect(keepMaps.count == 1)
        #expect(protectedSets.count == 1)

        // ⚠️ 不要写 `Set(keepMaps.first?.keys ?? [])` —— `Dictionary.Keys` **不是**
        // `ExpressibleByArrayLiteral`，`[]` 会被推断成 `[Any]` ⇒
        // `cannot convert value of type '[Any]' to expected argument type 'Dictionary<String, String>.Keys'`。
        // 2026-09-17 因此挂了一轮 CI：本机无 Swift 工具链、`build-package` 又不编译测试 target
        // ⇒ 这类错误只在 `swift-regression` 暴露（一轮白等 13–16 分钟）。
        guard let keepMap = keepMaps.first else {
            Issue.record("profileSweeper 没有收到 keep-map")
            return
        }
        let keptKeys = Set(keepMap.keys)
        let protected = protectedSets.first ?? []
        // 严格集合里**不该**有扩展（它不是 `.installed`）。
        let extensionInKeepMap = keptKeys.contains(extensionID)
        #expect(extensionInKeepMap == false)
        // 宽松集合里**必须**有扩展 —— 否则它会被当孤儿删掉。
        let extensionProtected = protected.contains(extensionID)
        #expect(extensionProtected == true)
        let mainProtected = protected.contains(mainID)
        #expect(mainProtected == true)
        // 两个集合**不能是同一个** —— 合成一个就是这次真机事故的成因。
        let identical = keptKeys == protected
        #expect(identical == false)
    }

    @Test
    func sealRunningProfileOverridesTheRecordedValue() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sealID = UUID()
        let store = InMemoryAppStore(records: [
            makeRecord(
                appID: sealID,
                mappedBundleIdentifier: "com.mjorb.seal.TEAMID",
                provisioningProfileUUID: "STALE-RECORD-UUID",
                isSeal: true
            )
        ])
        let sweeper = RecordingProfileSweeper()

        let job = makeJob(
            fixture,
            store: store,
            profileSweeper: sweeper,
            sealRunningProfileUUID: { "LIVE-RUNNING-UUID" }
        )
        _ = await job.run()

        // 记录里的值可能落后于现实；删掉正在用的那一份会让 Seal 下次启动直接失败。
        let maps = await sweeper.receivedKeepMaps
        #expect(maps.first?["com.mjorb.seal.TEAMID"] == "LIVE-RUNNING-UUID")
    }

    @Test
    func profileKeepMapIgnoresBlankValues() {
        let record = makeRecord(
            appID: UUID(),
            mappedBundleIdentifier: "   ",
            provisioningProfileUUID: "   "
        )
        let map = AppMaintenanceJob.profileKeepMap(records: [record], sealProfileUUID: nil)
        #expect(map.isEmpty)
    }

    @Test
    func extensionProfilesEnterTheKeepSetOnlyAfterAVerifiedInstall() {
        // 扩展记录是乐观值：签名阶段就写好了，不等安装校验通过。
        // 签名成功但安装失败时，它指向一份设备上不存在的 profile ——
        // 当成保留集合会删掉真正在用的那一份，扩展当场失效。
        let extensionRecord = AppExtensionRecord(
            name: "Share",
            originalBundleIdentifier: "com.example.demo.share",
            mappedBundleIdentifier: "com.example.demo.share",
            provisioningProfileUUID: "EXTENSION-UUID"
        )
        let installed = makeRecord(
            appID: UUID(),
            mappedBundleIdentifier: "com.example.demo",
            provisioningProfileUUID: "MAIN-UUID",
            signedArtifactStatus: .installed,
            extensions: [extensionRecord]
        )
        let installedMap = AppMaintenanceJob.profileKeepMap(
            records: [installed],
            sealProfileUUID: nil
        )
        #expect(installedMap["com.example.demo"] == "MAIN-UUID")
        #expect(installedMap["com.example.demo.share"] == "EXTENSION-UUID")

        let awaiting = makeRecord(
            appID: UUID(),
            mappedBundleIdentifier: "com.example.demo",
            provisioningProfileUUID: "MAIN-UUID",
            signedArtifactStatus: .awaitingVerification,
            extensions: [extensionRecord]
        )
        let awaitingMap = AppMaintenanceJob.profileKeepMap(
            records: [awaiting],
            sealProfileUUID: nil
        )
        #expect(awaitingMap["com.example.demo"] == "MAIN-UUID")
        #expect(awaitingMap["com.example.demo.share"] == nil, "未确认安装的扩展 UUID 不可信")
    }

    @Test
    func sealKeepEntryNeverFallsBackToTheRecordedProfile() {
        // Seal 自己的记录值**尤其不可信**：自更新路径在签名阶段就把顶层
        // `provisioningProfileUUID` 乐观推进（`app.isSeal` ⇒ `advancesInstalledSnapshot`
        // 恒为 true），而安装可能没落盘（`SEAL-SELF-111`）⇒ 记录指向一份设备上并不存在的
        // profile。拿它当保留集合，设备上**正在用的那一份**会被判成旧账删掉
        // ⇒ Seal 当场打不开、「VPN 与设备管理」里的描述文件消失（真机构建 38）。
        let seal = makeRecord(
            appID: UUID(),
            mappedBundleIdentifier: "com.mjorb.seal.T3432ZHJUF9",
            provisioningProfileUUID: "OPTIMISTIC-NEW-UUID",
            signedArtifactStatus: .installed,
            isSeal: true
        )

        // ① 读到运行时身份 ⇒ 以它为准，覆盖记录里的乐观值。
        let withRunning = AppMaintenanceJob.profileKeepMap(
            records: [seal],
            sealProfileUUID: "RUNNING-OLD-UUID"
        )
        #expect(withRunning["com.mjorb.seal.T3432ZHJUF9"] == "RUNNING-OLD-UUID",
                "Seal 的保留项必须用运行时读到的真实 profile")

        // ② 读不到运行时身份 ⇒ 整条摘出保留集合（宁缺勿滥），
        //    绝不回退到被乐观推进的记录值。
        let withoutRunning = AppMaintenanceJob.profileKeepMap(
            records: [seal],
            sealProfileUUID: nil
        )
        #expect(withoutRunning["com.mjorb.seal.T3432ZHJUF9"] == nil,
                "读不到运行时身份时不得回退到记录值")

        // ③ 空白值同样不得回退。
        let blankRunning = AppMaintenanceJob.profileKeepMap(
            records: [seal],
            sealProfileUUID: "   "
        )
        #expect(blankRunning["com.mjorb.seal.T3432ZHJUF9"] == nil,
                "空白运行时值不得回退到记录值")
    }

    @Test
    func abortsBeforeProfileSweepWhenLeaseIsInvalidated() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sweeper = RecordingProfileSweeper()

        // 检查点 1 = 孤儿文件清理前，检查点 2 = 描述文件清理前 —— 在这里失效
        let job = makeJob(
            fixture,
            gate: AbortOnCheckpointGate(abortFromCheck: 2),
            profileSweeper: sweeper
        )
        let outcome = await job.run()

        guard case .aborted(let stage, _) = outcome else {
            Issue.record("检查点失效时应当中断，实际：\(outcome)")
            return
        }
        #expect(stage == "描述文件清理")
        let maps = await sweeper.receivedKeepMaps
        #expect(maps.isEmpty, "被打断后一份 profile 都不能删")
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

    private func makeRecord(
        appID: UUID,
        mappedBundleIdentifier: String? = nil,
        provisioningProfileUUID: String? = nil,
        signedArtifactStatus: SignedArtifactStatus? = nil,
        extensions: [AppExtensionRecord] = [],
        isSeal: Bool = false
    ) -> AppRecord {
        AppRecord(
            id: appID,
            originalBundleIdentifier: "com.seal.maintenance.\(appID.uuidString.prefix(8))",
            mappedBundleIdentifier: mappedBundleIdentifier,
            name: "维护测试应用",
            version: "1.0.0",
            buildNumber: "1",
            size: 1024,
            state: .imported,
            provisioningProfileUUID: provisioningProfileUUID,
            ipaRelativePath: "Apps/\(appID.uuidString)/Original.ipa",
            signedArtifactStatus: signedArtifactStatus,
            isSeal: isSeal,
            importedAt: Date(),
            extensions: extensions
        )
    }

    private func makeJob(
        _ fixture: Fixture,
        gate: (any MaintenanceLeasing)? = nil,
        store: InMemoryAppStore = InMemoryAppStore(),
        recovery: AppRecordRecovery? = nil,
        profileSweeper: (any StaleProfileSweeping)? = nil,
        sealRunningProfileUUID: (@Sendable () -> String?)? = nil
    ) -> AppMaintenanceJob {
        AppMaintenanceJob(
            // 默认闸门「永不失效」，用来测正常路径
            gate: gate ?? AbortOnCheckpointGate(abortFromCheck: .max),
            appStore: store,
            fileStore: fixture.fileStore,
            recovery: recovery,
            selfAppRegistrar: nil,
            logStore: nil,
            profileSweeper: profileSweeper,
            sealRunningProfileUUID: sealRunningProfileUUID
        )
    }

    private func completedReport(_ outcome: AppMaintenanceJob.Outcome) -> OrphanSweepReport? {
        guard case .completed(let report) = outcome else {
            Issue.record("应当正常完成，实际：\(outcome)")
            return nil
        }
        return report.orphans
    }
}

/// 记录「保留集合」的桩，用来断言维护作业到底把哪些 Bundle ID 交给了清理器。
/// 用 actor 而不是 class：协议要求 `Sendable`，而这里需要可变状态。
private actor RecordingProfileSweeper: StaleProfileSweeping {
    private(set) var receivedKeepMaps: [[String: String]] = []
    /// 同时记下「有没有要求回收孤儿」：这是「换 Apple ID 后旧 Team 后缀的 profile
    /// 到底会不会被清」的唯一开关，漏传就整条功能静默失效（不会编译失败）。
    private(set) var receivedReclaimFlags: [Bool] = []
    /// 记下「宽松受保护集合」：它决定「谁不许成为回收候选」，
    /// 与 keep-map（决定「留哪一份」）是两个不同的集合。
    /// 调用方漏传 ⇒ 其它 App 的**扩展**会被当孤儿删掉（真机发生过）。
    private(set) var receivedProtectedSets: [Set<String>] = []

    func sweepStaleProfiles(
        keepingByBundleID: [String: String],
        protectedBundleIDs: Set<String>,
        reclaimSealOrphans: Bool
    ) async -> ProfileCleanupSummary {
        receivedKeepMaps.append(keepingByBundleID)
        receivedProtectedSets.append(protectedBundleIDs)
        receivedReclaimFlags.append(reclaimSealOrphans)
        return ProfileCleanupSummary()
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
