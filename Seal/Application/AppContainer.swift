import Foundation

@MainActor
struct AppContainer {
    let appsViewModel: AppsViewModel
    let settingsViewModel: SettingsViewModel
    let certificateExportHandler: CertificateExportHandler
    /// 后台保活（静音音频无限循环）。由 `SealApp.init()` 启动 —— 快捷指令在后台唤起 Seal
    /// 时走的也是那条路径（`SealAppEnvironment` ⇒ `RefreshAllAppsIntent`）。
    ///
    /// ⚠️ UI 测试与「存储初始化失败」两条分支传的是**不带日志**的实例：前者不该在测试里
    /// 真的放音频，后者连日志文件都没建起来。保活失败不影响续签本身（见该类的 `start()`）。
    let backgroundKeepAlive: BackgroundKeepAliveService
    /// 后台保活第二路（后台定位），与 `backgroundKeepAlive` 形成双保险。启动点与它相同。
    let locationKeepAlive: LocationKeepAliveService
    /// 迁移/启动类日志用。UI 测试与「存储初始化失败」两条分支为 `nil`（那时日志文件都没建起来）。
    let logStore: SealLogStore?

    /// 把升级前写入的 `WhenUnlocked` 钥匙串条目迁到「首次解锁后可读」——
    /// **这是「锁屏下快捷指令续签」的必要条件**（判据与原因见 `SealKeychainAccessibility`）。
    ///
    /// 🔴 **必须同步跑**：`SealApp.init()` 是进程最早执行点，快捷指令冷启动的续签在那之后
    /// 才读钥匙串 —— 做成 `Task` 会和续签抢时序（续签前那道通道等待**通常**够，但不保证）。
    ///
    /// 🔴 **必须有两个调用点**：
    ///   · `SealApp.init()`（正常启动）；
    ///   · `RootTabView` 的 `scenePhase == .active`（**补做**）。
    /// 只挂 init 有真实缺口：进程若在锁屏时被快捷指令冷启动，那次迁移会被系统拒绝
    /// （`errSecInteractionNotAllowed`），而保活又让这个进程活很久 —— 用户解锁后打开 Seal 时
    /// `init()` 不会再跑，迁移就一直没有机会做，锁屏续签会继续失败。
    ///
    /// 幂等：迁过一次后用 `KeychainAccessibilityMigrationMarker` 短路（避免刷日志）。
    func migrateKeychainAccessibilityIfNeeded() {
        guard let summary = KeychainAccessibilityMigrator.runSynchronously() else { return }
        Task { await KeychainAccessibilityMigrator.log(summary: summary, logStore: logStore) }
    }

    static func live(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> AppContainer {
        if let testModel = AppsViewModel.uiTestModel(arguments: arguments) {
            return AppContainer(
                appsViewModel: testModel,
                settingsViewModel: .preview(),
                certificateExportHandler: CertificateExportHandler(
                    keychain: KeychainVault(),
                    signingPreferenceStore: SigningPreferenceStore()
                ),
                backgroundKeepAlive: BackgroundKeepAliveService(logStore: nil),
                locationKeepAlive: LocationKeepAliveService(logStore: nil),
                logStore: nil
            )
        }

        do {
            let fileManager = FileManager.default
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw AppStoreError.invalidConfiguration
            }
            let sealDirectory = applicationSupport.appending(
                path: AppConfiguration.Paths.applicationSupportSubdirectory,
                directoryHint: .isDirectory
            )
            try fileManager.createDirectory(
                at: sealDirectory,
                withIntermediateDirectories: true
            )
            try CompleteFileProtector().protect(sealDirectory)

            let appStore = try Self.makeAppStore(in: sealDirectory)
            let fileStore = try AppFileStore.live()
            let accountRepository = ProtectedAccountRepository(
                fileURL: sealDirectory.appending(path: AppConfiguration.Paths.accountsFile)
            )
            let keychain = KeychainVault()
            let signingPreferenceStore = SigningPreferenceStore()
            let certificateExportHandler = CertificateExportHandler(
                keychain: keychain,
                signingPreferenceStore: signingPreferenceStore
            )
            let pairingStore = PairingStore(
                fileURL: sealDirectory.appending(path: AppConfiguration.Paths.pairingFile)
            )
            let anisetteProvider = AnisetteV3Client()
            // logStore 必须先于 installChannel 构造：安装链路（尤其自替换）现在会写日志。
            // 在这之前它一行日志都没有 —— 真机卡住时只剩「签名产物核验通过」然后一片空白。
            let logStore = SealLogStore(
                fileURL: sealDirectory.appending(path: AppConfiguration.Paths.sealLogFile)
            )
            let installChannel = MinimuxerInstallChannel(
                pairingStore: pairingStore,
                logDirectory: sealDirectory.appending(
                    path: AppConfiguration.Paths.minimuxerLogsSubdirectory,
                    directoryHint: .isDirectory
                ),
                logStore: logStore
            )
            let operationCoordinator = OperationCoordinator()
            let workflow = ImportWorkflow(
                parser: IPAParserService(),
                fileStore: fileStore,
                appStore: appStore,
                // 兜底判据用：导入的 IPA 就是这个**正在运行**的 Seal 自己时，
                // 必须按自更新处理（见 `ImportWorkflow.existingSealRecord`）。
                runningSealBundleIdentifier: Bundle.main.bundleIdentifier
            )
            // 启动即创建/更新 Documents/Seal-log.txt，让文件 App 中的 Seal 目录始终可见。
            // flush 会先加载已有日志，不会因本次镜像而清空历史。
            Task { await logStore.flush() }
            // 自替换事务与旧版 handoff 共用同一文件路径；新事务存取器在读取时
            // 自动把遗留 handoff 记录迁移成事务，无需保留旧存取器实例。
            let identityReader = AppBundleSigningIdentityReader()
            let transactionStore = SelfReplacementTransactionStore(
                fileURL: sealDirectory.appending(path: "SelfSigningHandoff.json")
            )
            let selfReplacement = SelfReplacementCoordinator(
                store: transactionStore,
                identityReader: identityReader,
                ipaIdentityReader: SignedIPAIdentityReader(bundleReader: identityReader),
                installChannel: installChannel,
                fileStore: fileStore,
                keychain: keychain,
                processID: SelfReplacementProcess.currentID,
                logStore: logStore
            )
            let signingCoordinator = SigningCoordinator(
                appStore: appStore,
                accountRepository: accountRepository,
                keychain: keychain,
                fileStore: fileStore,
                installChannel: installChannel,
                portal: ApplePortalSigningService(
                    anisetteProvider: anisetteProvider,
                    logStore: logStore
                ),
                logStore: logStore,
                selfReplacement: selfReplacement
            )
            let refreshQueueStore = RefreshQueueStore(
                fileURL: sealDirectory.appending(path: AppConfiguration.Paths.refreshQueueFile)
            )
            let pendingBatchResultStore = PendingBatchResultStore(
                fileURL: sealDirectory.appending(path: "PendingBatchResult.json")
            )
            let signingHistoryStore = SigningHistoryStore(
                fileURL: sealDirectory.appending(path: AppConfiguration.Paths.signingHistoryFile)
            )
            let notificationScheduler = ExpiryNotificationScheduler()
            let notificationPreferences = NotificationPreferences()
            let renewalCoordinator = RenewalCoordinator(
                appStore: appStore,
                signingCoordinator: signingCoordinator,
                queueStore: refreshQueueStore,
                defaultAccountIDProvider: {
                    let activeID = await signingPreferenceStore.activeAccountID()
                    if let activeID,
                       let accounts = try? await accountRepository.fetchAll(),
                       accounts.contains(where: { $0.id == activeID && AccountAvailabilityPolicy.isSelectable($0) }) {
                        return activeID
                    }
                    if let accounts = try? await accountRepository.fetchAll(),
                       let firstSelectable = accounts.first(where: { AccountAvailabilityPolicy.isSelectable($0) }) {
                        return firstSelectable.id
                    }
                    return nil
                },
                accountsProvider: {
                    (try? await accountRepository.fetchAll()) ?? []
                },
                // 批量续签的逐项成功日志（SEAL-RENEW-020）走这里。
                // 漏传不会编译失败，只会让「批量到底成没成」重新变成日志里的空白 ——
                // 守卫 R12 断言了这个实参存在。
                logStore: logStore
            )
            let appRecordRecovery = AppRecordRecovery(
                appStore: appStore,
                fileStore: fileStore,
                accountsProvider: {
                    (try? await accountRepository.fetchAll()) ?? []
                },
                // 生产路径接上真扫描器。**漏接线不会编译失败**，只会让扫回永远停在
                // `skipped-not-wired`（静默失效）—— 守卫 R80 的 `Scan/wire` 钉住它。
                deviceScanner: DeviceInstalledAppScanner.live
            )
            let selfAppRegistrar = SelfAppMetadata.current().map {
                SelfAppRegistrar(
                    metadata: $0,
                    appStore: appStore,
                    accountRepository: accountRepository,
                    fileStore: fileStore,
                    selfReplacement: selfReplacement,
                    profileCleaner: DeviceProfileCleaner(
                        readRunningIdentity: {
                            try identityReader.read(bundleURL: Bundle.main.bundleURL)
                        }
                    ),
                    keychain: keychain,
                    logStore: logStore,
                    pendingBatchResultStore: pendingBatchResultStore,
                    refreshQueueStore: refreshQueueStore
                )
            }
            // 维护作业：记录恢复 / Seal 自注册 / 孤儿文件清理 / 设备端旧描述文件清理。
            // 通过 MaintenanceGate 只在空闲时运行，永不阻塞用户的前台操作。
            let maintenanceJob = AppMaintenanceJob(
                gate: MaintenanceGate(coordinator: operationCoordinator),
                appStore: appStore,
                fileStore: fileStore,
                recovery: appRecordRecovery,
                selfAppRegistrar: selfAppRegistrar,
                logStore: logStore,
                profileSweeper: DeviceProfileCleaner()
            )

            return AppContainer(
                appsViewModel: AppsViewModel(
                    workflow: workflow,
                    appStore: appStore,
                    fileStore: fileStore,
                    accountRepository: accountRepository,
                    keychain: keychain,
                    signingCoordinator: signingCoordinator,
                    installChannel: installChannel,
                    renewalCoordinator: renewalCoordinator,
                    logStore: logStore,
                    signingHistoryStore: signingHistoryStore,
                    notificationScheduler: notificationScheduler,
                    notificationPreferences: notificationPreferences,
                    backgroundRenewalNotifier: BackgroundRenewalNotifier(),
                    signingPreferenceStore: signingPreferenceStore,
                    operationCoordinator: operationCoordinator,
                    maintenanceJob: maintenanceJob
                ),
                settingsViewModel: SettingsViewModel(
                    accountRepository: accountRepository,
                    keychain: keychain,
                    accountClient: AppleAccountClient(
                        anisetteProvider: anisetteProvider
                    ),
                    pairingStore: pairingStore,
                    installChannel: installChannel,
                    appStore: appStore,
                    fileStore: fileStore,
                    logStore: logStore,
                    signingHistoryStore: signingHistoryStore,
                    notificationScheduler: notificationScheduler,
                    notificationPreferences: notificationPreferences,
                    anisetteEnvironment: anisetteProvider,
                    signingPreferenceStore: signingPreferenceStore,
                    operationCoordinator: operationCoordinator,
                    selfReplacementStore: transactionStore
                ),
                certificateExportHandler: certificateExportHandler,
                backgroundKeepAlive: {
                    let service = BackgroundKeepAliveService(logStore: logStore)
                    // 续签完成后停止保活（省电）：快捷指令下次触发时会重新 start()
                    Task { @MainActor in
                        for await _ in NotificationCenter.default.notifications(named: .sealRenewalCompleted) {
                            service.stop()
                        }
                    }
                    return service
                }(),
                locationKeepAlive: {
                    let service = LocationKeepAliveService(logStore: logStore)
                    Task { @MainActor in
                        for await _ in NotificationCenter.default.notifications(named: .sealRenewalCompleted) {
                            service.stop()
                        }
                    }
                    return service
                }(),
                logStore: logStore
            )
        } catch {
            let failure = ImportFailure(
                title: "无法打开数据",
                reason: "本地存储初始化失败：\(Self.readableStartupError(error))",
                recovery: "重启 Seal 重试；如仍失败请检查设备剩余存储空间",
                code: "SEAL-APP-001"
            )
            return AppContainer(
                appsViewModel: AppsViewModel(startupFailure: failure),
                settingsViewModel: SettingsViewModel(startupFailure: failure),
                certificateExportHandler: CertificateExportHandler(
                    keychain: KeychainVault(),
                    signingPreferenceStore: SigningPreferenceStore()
                ),
                backgroundKeepAlive: BackgroundKeepAliveService(logStore: nil),
                locationKeepAlive: LocationKeepAliveService(logStore: nil),
                logStore: nil
            )
        }
    }
    private static func makeAppStore(in sealDirectory: URL) throws -> CoreDataAppStore {
        let storeURL = sealDirectory.appending(path: "Seal.sqlite")
        do {
            return try CoreDataAppStore(storeURL: storeURL)
        } catch {
            try backupUnreadableSQLiteStore(
                at: storeURL,
                in: sealDirectory,
                originalError: error
            )
            return try CoreDataAppStore(storeURL: storeURL)
        }
    }

    private static func backupUnreadableSQLiteStore(
        at storeURL: URL,
        in sealDirectory: URL,
        originalError: Error
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storeURL.path) else {
            throw originalError
        }

        let recoveryDirectory = sealDirectory.appending(
            path: "StorageRecovery-\(compactTimestamp())",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: recoveryDirectory,
            withIntermediateDirectories: true
        )

        var didMoveAnyFile = false
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = recoveryDirectory.appending(path: source.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: source, to: destination)
            didMoveAnyFile = true
        }

        guard didMoveAnyFile else { throw originalError }
    }

    private static func compactTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func readableStartupError(_ error: Error) -> String {
        if let failure = error as? ImportFailure {
            return failure.userMessage
        }
        return (error as NSError).localizedDescription
    }
}
