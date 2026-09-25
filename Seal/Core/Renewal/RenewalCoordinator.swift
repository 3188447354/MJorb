import Foundation

struct BatchRefreshResult: Equatable, Sendable {
    let total: Int
    let succeeded: Int
    let failed: Int
    /// 本轮**根本没执行**、等用户先处理的项（缺可用账号等）。
    /// 与 `failed` 分开计数：「试过了没成」和「没试，缺前置条件」需要不同的下一步动作。
    let needsAction: Int
    /// Seal 覆盖安装已提交，等待新进程读回实际运行身份；它既不是成功也不是失败。
    let awaitingConfirmation: Int

    /// 仍未成功（失败 + 待处理）。保留原有语义供既有 UI 使用。
    var remaining: Int { max(0, total - succeeded) }

    /// 每一项都必须落进恰好一个桶里。等式不成立就说明有项被静默丢了 ——
    /// 这正是旧实现「批量续签完成，其实有应用没被处理」的病根。
    var isBalanced: Bool {
        succeeded + failed + needsAction + awaitingConfirmation == total
    }
}

enum BatchRefreshEvent: Sendable {
    case prepared(apps: [AppRecord])
    case started(total: Int)
    case appProgress(index: Int, total: Int, app: AppRecord, stage: SigningStage)
    /// 安装通道 AFC 上传的真实进度（0-1），仅 `.pushing` 阶段有值。
    ///
    /// 单独一个事件而不是塞进 `appProgress`：上传进度是**高频**回调（逐百分比），
    /// 混进阶段事件会让「阶段变化」这个低频信号被淹没，消费端也难以区分
    /// 「阶段推进了」和「同一个阶段里进度动了」。
    case appInstallProgress(index: Int, total: Int, app: AppRecord, progress: Double)
    /// 阶段内部可数的完成量（第 i / N 个 Bundle ID、第 i / N 份描述文件）。
    ///
    /// 与 `appInstallProgress` 同样**单独一个事件**、不塞进 `appProgress`：它也是高频回调，
    /// 混进阶段事件会把低频的「阶段推进」淹掉。
    case appWorkUnits(index: Int, total: Int, app: AppRecord, units: SigningWorkUnits)
    case appRenewalExecutionPath(index: Int, total: Int, app: AppRecord, path: RenewalExecutionPath)
    case appAwaitingSealConfirmation(index: Int, total: Int, app: AppRecord)
    case appSucceeded(index: Int, total: Int, app: AppRecord)
    case appFailed(index: Int, total: Int, app: AppRecord, failure: ImportFailure)
}

actor RenewalCoordinator {
    private let appStore: any AppStore
    private let signingCoordinator: SigningCoordinator
    private let queueStore: RefreshQueueStore
    private let planner: RefreshPlanner
    private let defaultAccountIDProvider: (@Sendable () async -> UUID?)?
    private let accountsProvider: (@Sendable () async -> [AppleAccountRecord])?
    /// 逐项结果要落日志。
    ///
    /// 批量续签原来**一条逐项结果都不写** —— 「续签并安装成功」只在单签路径
    /// （`AppsViewModel.signAndInstall`）里写，而批量走的是本协调器直接调
    /// `SigningCoordinator.signAndInstall`。后果是真机上「某个 App 到底成没成」
    /// 只能靠推断（2026-09-17：用户取消批量后看到 App 像是重装了，却无法确认），
    /// 排障时拿到的只有日志，日志里却没有结论。
    private let logStore: SealLogStore?

    /// 本项续签**实际**走的路径，由 `SigningCoordinator` 在设备端身份核验之后回调写入。
    ///
    /// 🔴 结算时必须用它区分两件事（2026-09-25）：
    ///   · `.profileOnly` —— 只换描述文件，**进程不受影响** ⇒ 可以直接记成功；
    ///   · `.fullResign`  —— 重新签名 + **覆盖安装 Seal 自己** ⇒ 当前进程会被系统换掉
    ///     ⇒ 那一项必须保持 `running`，交给下次启动按真实运行包身份结算。
    /// 旧实现只按 `updated.isSeal` 判断，等于**假定 Seal 续签必然是自替换** ——
    /// 准入判据放行 profile-only 之后，这个假定会让「其实已经成功、进程也没重启」的
    /// 那一项永远停在等待确认里，重新变成 `SEAL-RENEW-007`「结果未知」。
    ///
    /// ⚠️ 判据用 `!= .profileOnly`（**没有明确确认是快路径就按保守处理**）：
    /// 信号缺失时保持旧行为，只会多一次「等待新进程核验」，不会把可能已被换掉的进程
    /// 谎报成已完成。
    private var currentRenewalExecutionPath: RenewalExecutionPath?

    /// 记录本项续签实际走的路径。由 `@Sendable` 回调调用，故单独开一个 actor 方法。
    private func rememberRenewalExecutionPath(_ path: RenewalExecutionPath) {
        currentRenewalExecutionPath = path
    }

    /// 单个应用续签总尝试次数上限，仅临时网络故障允许重试。
    private let maxAttempts = 3
    /// 重试前等待的基础秒数，第 n 次重试等待 baseRetryDelay * n。
    /// 涉及 Apple 限流自愈，刻意保守、不缩短；激进缩短会让 503 场景退避不足反而更慢。
    private let baseRetryDelay: UInt64 = 2_000_000_000
    /// 两个应用之间的间隔，给 Apple 服务器和本地安装通道缓冲。
    /// 应用内部本就含多段 Apple 往返（fetchTeams / App ID / profile），
    /// 此间隔仅兜底分批节奏；延续签优化从 1.5s 保守降至 0.75s，仍是「给服务器缓冲」语义。
    private let interAppDelay: UInt64 = 750_000_000

    init(
        appStore: any AppStore,
        signingCoordinator: SigningCoordinator,
        queueStore: RefreshQueueStore,
        planner: RefreshPlanner = RefreshPlanner(),
        defaultAccountIDProvider: (@Sendable () async -> UUID?)? = nil,
        accountsProvider: (@Sendable () async -> [AppleAccountRecord])? = nil,
        logStore: SealLogStore? = nil
    ) {
        self.appStore = appStore
        self.signingCoordinator = signingCoordinator
        self.queueStore = queueStore
        self.planner = planner
        self.defaultAccountIDProvider = defaultAccountIDProvider
        self.accountsProvider = accountsProvider
        self.logStore = logStore
    }

    func refreshAll(
        progress: @escaping @Sendable (BatchRefreshEvent) async -> Void
    ) async throws -> BatchRefreshResult {
        let apps = try await appStore.fetchAll()
        let queue = try await makeQueue(apps: apps)
        return try await run(queue: queue, progress: progress)
    }

    /// 只重试上一轮失败的应用，避免对已成功应用重复签名/上传/安装。
    func refreshFailedItems(
        appIDs: [UUID],
        progress: @escaping @Sendable (BatchRefreshEvent) async -> Void
    ) async throws -> BatchRefreshResult {
        try await refresh(appIDs: appIDs, progress: progress)
    }

    /// 指定应用的续签入口。单项续签、失败项重试与“全部续签”都复用同一规划、排序、
    /// 持久化与 Seal-last 结算规则；调用方只决定选择哪几项。
    func refresh(
        appIDs: [UUID],
        progress: @escaping @Sendable (BatchRefreshEvent) async -> Void
    ) async throws -> BatchRefreshResult {
        let apps = try await appStore.fetchAll()
        let selectedIDs = Set(appIDs)
        let queue = try await makeQueue(apps: apps).filter { selectedIDs.contains($0.appID) }
        return try await run(queue: queue, progress: progress)
    }

    /// 启动恢复：把上一轮被中断留下的 `running` 项降级为 `unknown`。
    ///
    /// 进程被杀（崩溃 / 被系统回收 / **自己替换自己**）时正在跑的项，签名+安装可能已落地、
    /// 也可能只做了一半，**既不能当成功也不能当失败**。不做这一步它就会永久停在 `running`：
    /// 既不在失败列表（不会被重试），也不是 `completed`（不会被清理）。
    ///
    /// ⚠️ 但**已经拿到结论的项不许降级**：Seal 自替换时那一项的结果已经写进持久化载荷了，
    /// 盲目降级会让日志报假警报、队列留幽灵条目，而结果抽屉同时显示成功。
    /// 调用方负责把已知结论传进来（见 `AppsViewModel.recoverInterruptedQueueIfNeeded`）。
    ///
    /// - Parameter settled: 已经从持久化载荷拿到结论的项（appID → 状态）。
    @discardableResult
    func recoverInterruptedQueue(
        settled: [UUID: RefreshQueueItem.State] = [:]
    ) async throws -> RefreshQueueStore.RecoveryOutcome {
        try await queueStore.recoverInterrupted(settled: settled)
    }

    /// 本轮结束后仍需处理的项（失败 / 未执行 / 结果未知），保持持久化顺序。
    func outstandingQueueItems() async throws -> [RefreshQueueItem] {
        try await queueStore.outstanding()
    }

    private func makeQueue(apps: [AppRecord]) async throws -> [RefreshQueueItem] {
        let fallbackAccountID: UUID?
        if let provider = defaultAccountIDProvider {
            fallbackAccountID = await provider()
        } else {
            fallbackAccountID = nil
        }
        let allAccounts: [AppleAccountRecord]
        if let provider = accountsProvider {
            allAccounts = await provider()
        } else {
            allAccounts = []
        }
        return planner.makeQueue(
            apps: apps,
            fallbackAccountID: fallbackAccountID,
            accounts: allAccounts
        )
    }

    private func run(
        queue: [RefreshQueueItem],
        progress: @escaping @Sendable (BatchRefreshEvent) async -> Void
    ) async throws -> BatchRefreshResult {
        let apps = try await appStore.fetchAll()
        let queuedApps = queue.compactMap { item in apps.first(where: { $0.id == item.appID }) }
        await progress(.prepared(apps: queuedApps))
        try await queueStore.replace(with: queue)
        return try await process(queue: queue, progress: progress)
    }

    /// Retry only classified transient network errors. Authentication, certificate,
    /// storage and package failures need an explicit recovery action. Installation
    /// already has its own retry budget; do not multiply it by resigning the app.
    nonisolated static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let failure = error as? ImportFailure {
            return failure.code.hasPrefix("SEAL-NET-")
        }
        return AppleServiceFailurePolicy.isNetworkError(error)
    }

    /// 把任意错误归一化成 ImportFailure，同时保留原始错误描述，不再吞掉根因
    private func normalize(_ error: Error) -> ImportFailure {
        if let failure = error as? ImportFailure { return failure }
        let nsError = error as NSError
        let detail = "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
        return ImportFailure(
            title: "续签失败",
            reason: "续签过程遇到临时错误（\(detail)），已自动重试仍未恢复。",
            recovery: "检查网络后重试；如持续失败请导出日志反馈",
            code: "SEAL-RENEW-500"
        )
    }

    private func process(
        queue: [RefreshQueueItem],
        progress: @escaping @Sendable (BatchRefreshEvent) async -> Void
    ) async throws -> BatchRefreshResult {
        await progress(.started(total: queue.count))
        var succeeded = 0
        var failed = 0
        var needsAction = 0
        var awaitingConfirmation = 0

        for (offset, item) in queue.enumerated() {
            try Task.checkCancellation()

            // 本轮不执行的项（缺可用账号等）。**不静默跳过**：计入 needsAction，
            // 并复用失败条目的呈现把原因摊给用户 —— 否则「批量续签完成」会掩盖
            // 「有应用根本没被处理」这个事实。
            guard item.isExecutable, let accountID = item.accountID else {
                needsAction += 1
                await emitFailure(
                    progress: progress,
                    offset: offset,
                    total: queue.count,
                    item: item,
                    failure: Self.requiresActionFailure(reason: item.requiresActionReason)
                )
                continue
            }

            // 应用之间留出缓冲，避免连续请求 Apple 服务器触发限流；第一个不用等
            if offset > 0 {
                try? await Task.sleep(nanoseconds: interAppDelay)
            }

            // 先确认记录存在；具体最新状态在每次尝试时重新读取（失败可能已改写 Bundle ID/证书）
            let initialApps = try await appStore.fetchAll()
            guard initialApps.contains(where: { $0.id == item.appID }) else {
                // 本地记录确实不存在，无法续签
                let failure = ImportFailure(
                    title: "无法续签应用",
                    reason: "续签时未找到应用（ID：\(item.appID)）的本地记录。",
                    recovery: "重新导入 IPA 并签名安装",
                    code: "SEAL-RENEW-404"
                )
                try? await queueStore.markFailed(appID: item.appID, errorCode: failure.code)
                failed += 1
                await emitFailure(progress: progress, offset: offset, total: queue.count, item: item, failure: failure)
                continue
            }

            // —— 自动重试循环：最多 maxAttempts 次 ——
            var lastError: Error?
            var updatedRecord: AppRecord?
            // 路径信号按项重置：上一项的 `.profileOnly` 绝不能泄漏到下一项
            //（泄漏的后果是 Seal 那一项被误记成成功，而它其实换了进程）。
            currentRenewalExecutionPath = nil

            for attempt in 1...maxAttempts {
                // 每次尝试都重新读取最新记录
                guard let app = (try? await appStore.fetchAll())?.first(where: { $0.id == item.appID }) else {
                    lastError = ImportFailure(
                        title: "无法续签应用",
                        reason: "续签时未找到应用（ID：\(item.appID)）的本地记录。",
                        recovery: "重新导入 IPA 并签名安装",
                        code: "SEAL-RENEW-404"
                    )
                    break
                }
                do {
                    try Task.checkCancellation()
                    try await queueStore.markRunning(appID: item.appID)
                    let latestApp = app
                    let updated = try await signingCoordinator.signAndInstall(
                        appID: item.appID,
                        accountID: accountID,
                        requestedBundleIdentifier: latestApp.mappedBundleIdentifier ?? latestApp.preferredBundleIdentifier,
                        selectedCertificateSerialNumber: nil,
                        forceResign: true,
                        // 续签是覆盖已装应用，不新增免费账号设备槽位；已绕过 3-app 上限
                        // （设备级跨 team）装 6 个应用的用户，批量续签时必须跳过本机预检，
                        // 交回 installd 裁决，否则全部被 SEAL-APPID-DEVICELIMIT 误拦。
                        bypassFreeAccountDeviceLimit: true,
                        // ⚠️ 证书轮换子流程也会走这个回调，而它推进的是**另一个** App 的阶段。
                        // 批量链路**刻意仍用本项的 `latestApp` 当事件主体**：批量的
                        // 「Seal 自替换 ⇒ 回主屏」由队列自己的 Seal 项驱动（Seal 恒排最后），
                        // 若在这里改用信号主体，就会在队列中段交前台、把还没跑的项全丢掉。
                        // ⇒ 只取 `update.stage`，主体保持 `latestApp`（单签链路才用信号主体）。
                        progress: { update in
                            // 自更新上传开始不代表安装成功。进程被终止时保留 running，
                            // 下次启动恢复为 unknown；不能把仍运行旧包的续签记为完成。
                            await progress(
                                .appProgress(
                                    index: offset + 1,
                                    total: queue.count,
                                    app: latestApp,
                                    stage: update.stage
                                )
                            )
                        },
                        onRenewalExecutionPath: { path in
                            // 先记进 actor（结算要用它判断「Seal 是否真的重新安装了自己」），
                            // 再推给界面。顺序无关紧要，但两件事都必须做。
                            await self.rememberRenewalExecutionPath(path)
                            await progress(
                                .appRenewalExecutionPath(
                                    index: offset + 1,
                                    total: queue.count,
                                    app: latestApp,
                                    path: path
                                )
                            )
                        },
                        // 上传百分比单独走 appInstallProgress：抽屉要显示真实百分比，
                        // 否则「传输中」就是一个没有分母的黑盒（2026-09-16 真机反馈）。
                        onInstallProgress: { installProgress in
                            await progress(
                                .appInstallProgress(
                                    index: offset + 1,
                                    total: queue.count,
                                    app: latestApp,
                                    progress: installProgress
                                )
                            )
                        },
                        // 上传完成的 1.01 哨兵在这里被补发成 `.installing` 阶段事件
                        // （批量 progress 回调只承载 SigningStage，看不到 Double 哨兵）。
                        // 覆盖本轮全部应用：Seal 靠它触发自动回主页，普通 App 靠它把抽屉
                        // 文案从「传输中」推进到「安装中」，不再整段静止。
                        //
                        // 实参顺序必须与 signAndInstall 的声明一致（onInstallProgress
                        // 在 broadcastsInstallStage 之前）—— 写反了是编译错误，
                        // 而本机没有 Swift 工具链、build-package 又不编译测试 target，
                        // 只有守卫 R09 能提前拦住（2026-09-16 实际踩到一次）。
                        broadcastsInstallStage: true,
                        // 阶段内部**可数**的完成量（注册第 i / N 个 Bundle ID、取第 i / N
                        // 份描述文件）。批量抽屉的轨道用它把那两格从「按 τ 慢爬」变成
                        // 「一格一格跳」；没有它的阶段仍走估算，界面上不报百分比。
                        onWorkUnits: { units in
                            await progress(
                                .appWorkUnits(
                                    index: offset + 1,
                                    total: queue.count,
                                    app: latestApp,
                                    units: units
                                )
                            )
                        }
                    )
                    updatedRecord = updated
                    lastError = nil
                    break
                } catch is CancellationError {
                    do {
                        try await queueStore.markPending(appID: item.appID)
                    } catch {
                        throw Self.queuePersistenceFailure(
                            reason: "取消续签后，队列状态未能保存。",
                            code: "SEAL-RENEW-QUEUE-002"
                        )
                    }
                    throw CancellationError()
                } catch {
                    lastError = error
                    // 还能重试就等待后继续
                    if attempt < maxAttempts && Self.isRetryable(error) {
                        let delay = baseRetryDelay * UInt64(attempt)
                        try? await Task.sleep(nanoseconds: delay)
                        continue
                    }
                    break
                }
            }

            if let updated = updatedRecord {
                // ⚠️ 「Seal 续签」**不再必然**意味着自替换（2026-09-25）：准入判据放行后，
                // Seal 与普通应用一样可以只换描述文件，**进程不受影响** ⇒ 这一项就是
                // 一个正常的成功项，不需要「留给新进程核验」。
                // 只有 `fullResign`（重新签名 + 覆盖安装自己）才会把当前进程换掉。
                // ⇒ 判据是**实际路径**，不是应用身份；用 `!= .profileOnly` 让信号缺失时
                //   退回保守行为（多等一次核验，而不是谎报成功）。
                if updated.isSeal, currentRenewalExecutionPath != .profileOnly {
                    // 自替换会杀掉当前进程；只有新进程读取运行包身份并与候选相符后，
                    // 才能写 completed。队列保持 running，交给启动期对账结算。
                    awaitingConfirmation += 1
                    try? await logStore?.append(
                        category: .renewal,
                        message: "批量续签：Seal 覆盖安装已提交，等待新进程核验运行包身份",
                        code: "SEAL-RENEW-027"
                    )
                    await progress(
                        .appAwaitingSealConfirmation(
                            index: offset + 1,
                            total: queue.count,
                            app: updated
                        )
                    )
                    continue
                }
                try await queueStore.markCompleted(appID: item.appID)
                succeeded += 1
                // 逐项成功留痕（含描述文件身份）。
                //
                // 缺这条日志时，「批量续签到底成没成」在日志里**完全查不到**：
                // 批量走 `SigningCoordinator.signAndInstall`，而「续签并安装成功」
                // 只在**单签**的 `AppsViewModel.signAndInstall` 里写。
                // 2026-09-17 真机实测 —— 用户续签 LiveContainer 时界面停在「安装中」，
                // 取消后无从判断到底装没装上（实际成功了），就是因为这里静默。
                //
                // 带上描述文件 UUID + 创建/到期时间：这三个字段是**自证**用的，
                // 用户可以在应用详情页对着看，确认记录指向的就是刚申请的那一份。
                try? await logStore?.append(
                    category: .renewal,
                    message: "批量续签：第 \(offset + 1)/\(queue.count) 项成功 —— \(updated.mappedBundleIdentifier ?? updated.preferredBundleIdentifier ?? updated.originalBundleIdentifier)，描述文件 \(Self.describeProfile(updated))",
                    code: "SEAL-RENEW-020"
                )
                await progress(
                    .appSucceeded(
                        index: offset + 1,
                        total: queue.count,
                        app: updated
                    )
                )
            } else if let lastError {
                // 重试用尽，判失败
                let failure = normalize(lastError)
                do {
                    try await queueStore.markFailed(
                        appID: item.appID,
                        errorCode: failure.code
                    )
                } catch {
                    throw Self.queuePersistenceFailure(
                        reason: "续签失败状态未能写入队列。",
                        code: "SEAL-RENEW-QUEUE-003"
                    )
                }
                failed += 1
                await emitFailure(progress: progress, offset: offset, total: queue.count, item: item, failure: failure)
            }
        }

        do {
            try await queueStore.removeCompleted()
        } catch {
            throw Self.queuePersistenceFailure(
                reason: "已完成的续签任务未能从队列中清理。",
                code: "SEAL-RENEW-QUEUE-005"
            )
        }
        return BatchRefreshResult(
            total: queue.count,
            succeeded: succeeded,
            failed: failed,
            needsAction: needsAction,
            awaitingConfirmation: awaitingConfirmation
        )
    }

    /// `requiresAction` 项使用的错误码。
    ///
    /// UI 靠它把「本轮未执行」与「尝试后失败」分开计数：前者下一步是去补前置条件
    /// （例如添加账号），后者才是重试。混在一起会让用户以为「重试就能好」。
    static let requiresActionCode = "SEAL-RENEW-006"

    /// `requiresAction` 项复用失败条目的呈现，但错误码独立、文案必须是可执行引导。
    private static func requiresActionFailure(reason: String?) -> ImportFailure {
        ImportFailure(
            title: "本轮未执行，需要先处理",
            reason: reason ?? "该应用缺少续签所需的前置条件。",
            recovery: "按上述说明处理后重新续签",
            code: requiresActionCode
        )
    }

    /// 描述文件身份的**自证串**：UUID + 创建时间 + 到期时间。
    ///
    /// 为什么这三个字段必须进日志：`SEAL-RENEW-020` 要回答的是
    /// 「这次续签到底给我换了一份**新的**描述文件吗，还是只是重签了旧的那份」。
    /// 只写「成功」两个字回答不了 —— 用户 2026-09-17 的困惑正是这个。
    /// 有了创建时间，日志本身就能自证：创建时间 ≈ 本次续签时刻 ⇒ 是新申请的；
    /// 创建时间是几天前 ⇒ 复用了旧的（此时到期日会明显偏早，需要留意）。
    ///
    /// 用 ISO8601 而不是本地化格式：导出日志后要能直接和 Apple 门户返回的时间对上。
    ///
    /// 非 private：它是这条日志里**唯一可测的纯函数**，行为由
    /// `RenewalCoordinatorLogTests` 钉住。源码断言只能证明「日志里有这个字段」，
    /// 证明不了它真的把 UUID 与时间写了出来。
    static func describeProfile(_ record: AppRecord) -> String {
        let uuid = record.provisioningProfileUUID ?? "未知"
        let created = record.provisioningProfileCreationDate
            .map { SealLogTextFormatter.diagnosticTimestamp($0) } ?? "未知"
        let expires = record.provisioningProfileExpirationDate
            .map { SealLogTextFormatter.diagnosticTimestamp($0) } ?? "未知"
        return "\(uuid)（创建 \(created)，到期 \(expires)）"
    }

    /// 失败后重新读取一次最新应用记录、**落一条日志**、再推送失败事件。
    ///
    /// 🔴 **日志那一步是 2026-09-24 补的**：原来这里只推 UI 事件 ⇒ 真机日志里
    /// 「批量续签完成：共 3，成功 1，失败 2」之后**什么都没有**，失败的是谁、为什么，
    /// 全查不出来 —— 而逐项**成功**早就有 `SEAL-RENEW-020`。
    /// 排障时手上只有日志，日志里却没有结论，等于没有失败信息（构建 33 第二轮实证）。
    ///
    /// 文案用「未成功」而不是「失败」：这条路径同时服务 `failed`（试过了没成）
    /// 与 `needsAction`（没试，缺前置条件）两种项，后者说「失败」会误导 ——
    /// 两者由 `failure.code` 区分（`needsAction` 走 `requiresActionCode`）。
    private func emitFailure(
        progress: @escaping @Sendable (BatchRefreshEvent) async -> Void,
        offset: Int,
        total: Int,
        item: RefreshQueueItem,
        failure: ImportFailure
    ) async {
        let currentApps = (try? await appStore.fetchAll()) ?? []
        let app = currentApps.first(where: { $0.id == item.appID })
        try? await logStore?.append(
            category: .renewal,
            level: .error,
            message: "批量续签：第 \(offset + 1)/\(total) 项未成功 —— \(app?.name ?? "记录已不存在")，[\(failure.code)] \(failure.title)：\(failure.reason)",
            code: "SEAL-RENEW-030"
        )
        if let app {
            await progress(
                .appFailed(
                    index: offset + 1,
                    total: total,
                    app: app,
                    failure: failure
                )
            )
        }
    }

    private static func queuePersistenceFailure(reason: String, code: String) -> ImportFailure {
        ImportFailure(
            title: "续签队列异常",
            reason: reason,
            recovery: "检查本机存储后重试",
            code: code
        )
    }

}
