import Foundation

/// 独立的维护作业：把原本挂在**读取路径**上的写操作收敛到一处，并统一加空闲租约。
///
/// 为什么顺序不能变：
/// 1. **记录恢复**（导入事务恢复 + 缺失记录补建）必须最先 —— 后面几步都依赖 DB 与文件已对齐。
/// 2. **Seal 自身注册**会重写 Seal 自己的应用目录，属于覆盖写操作。
/// 3. **孤儿文件清理**删的是本地文件。
/// 4. **旧描述文件清理**删的是设备端 profile，依赖前三步已把记录修正到位（保留集合来自记录），
///    所以放最后。
///
/// 每一步前后都检查 `MaintenanceGate.shouldAbort`：用户一旦开始签名 / 安装 / 续签，
/// 作业立即停止，并且**不再进入后续步骤**（尤其是删除）。
///
/// 另见 `MaintenanceGate` 的说明：维护作业永远不阻塞用户操作，非空闲就跳过本轮。
@MainActor
final class AppMaintenanceJob {
    /// 一轮维护的产出。分开记录「本地文件」与「设备 profile」两类删除，
    /// 便于在日志里区分「没清干净」到底是哪一类没跑。
    struct MaintenanceReport: Equatable, Sendable {
        var orphans: OrphanSweepReport
        /// 未接线 / 记录读取失败时是带 `skipped-*` stage 的空摘要，而不是 nil ——
        /// 「为什么一份都没删」必须留在结果里，不能只靠猜。
        var profiles: ProfileCleanupSummary
    }

    enum Outcome: Equatable {
        /// 非空闲，本轮完全没动（没有写入、没有删除）。
        case skipped
        case completed(MaintenanceReport)
        /// 中途发现前台操作启动，已停止；`stage` 记录停在哪一步。
        case aborted(stage: String, reason: String)
        case failed(ImportFailure)
    }

    private let gate: any MaintenanceLeasing
    private let appStore: any AppStore
    private let fileStore: AppFileStore
    private let recovery: AppRecordRecovery?
    private let selfAppRegistrar: SelfAppRegistrar?
    private let logStore: SealLogStore?
    private let profileSweeper: (any StaleProfileSweeping)?
    /// 读 Seal 自己**正在运行**的那份 profile UUID。记录里的值可能落后于现实，
    /// 而删掉正在用的那一份会让 Seal 下次启动直接失败，所以以运行时读数为准。
    private let sealRunningProfileUUID: (@Sendable () -> String?)?

    init(
        gate: any MaintenanceLeasing,
        appStore: any AppStore,
        fileStore: AppFileStore,
        recovery: AppRecordRecovery?,
        selfAppRegistrar: SelfAppRegistrar?,
        logStore: SealLogStore?,
        profileSweeper: (any StaleProfileSweeping)? = nil,
        sealRunningProfileUUID: (@Sendable () -> String?)? = nil
    ) {
        self.gate = gate
        self.appStore = appStore
        self.fileStore = fileStore
        self.recovery = recovery
        self.selfAppRegistrar = selfAppRegistrar
        self.logStore = logStore
        self.profileSweeper = profileSweeper
        self.sealRunningProfileUUID = sealRunningProfileUUID
    }

    func run() async -> Outcome {
        guard let token = gate.tryAcquire() else { return .skipped }
        defer { gate.end(token) }

        // ── 1. 记录恢复 ────────────────────────────────────────────────
        if let recovery {
            do {
                try await recovery.restoreMissingRecords()
            } catch let failure as ImportFailure {
                return .failed(failure)
            } catch {
                return .failed(Self.unexpectedFailure(stage: "记录恢复", error: error))
            }
            if gate.shouldAbort(token) {
                return .aborted(stage: "记录恢复", reason: "用户操作已开始")
            }
        }

        // ── 2. Seal 自身注册 ───────────────────────────────────────────
        if let selfAppRegistrar {
            do {
                try await selfAppRegistrar.ensureRegistered()
            } catch {
                // 自注册失败不阻断后续清理（清理是安全的：它只删 DB 里没有引用的目录），
                // 但必须留痕，不能静默吞掉。
                try? await logStore?.append(
                    category: .system,
                    level: .warning,
                    message: "Seal 自身记录同步失败",
                    code: "SEAL-SELF-REG-001"
                )
            }
            if gate.shouldAbort(token) {
                return .aborted(stage: "Seal 自身注册", reason: "用户操作已开始")
            }
        }

        // ── 3. 孤儿文件清理（本地删除）────────────────────────────────
        let orphanReport: OrphanSweepReport
        do {
            // 删除前复核 DB 引用：**现在**取一次有效 ID，不复用作业开始时或更早的快照。
            // 快照与删除之间只要有新记录写入，就会把新应用的文件目录当孤儿删掉。
            guard gate.shouldAbort(token) == false else {
                return .aborted(stage: "孤儿文件清理", reason: "用户操作已开始")
            }
            let currentRecords = try await appStore.fetchAll()
            orphanReport = try await fileStore.clearOrphanedAppFiles(
                validAppIDs: Set(currentRecords.map(\.id))
            )
        } catch let failure as ImportFailure {
            return .failed(failure)
        } catch {
            return .failed(Self.unexpectedFailure(stage: "孤儿文件清理", error: error))
        }

        // ── 4. 设备端旧描述文件清理（设备删除，最佳努力）─────────────────
        // 免费账号反复续签会在设备端累积 profile：Seal 自己、以及每个被签 App 的每个扩展
        // 各留一份。这里按「记录里当前在用的那一份」保留、其余删除。
        let profileOutcome = await sweepStaleProfiles(token: token)
        switch profileOutcome {
        case .aborted(let stage, let reason):
            return .aborted(stage: stage, reason: reason)
        case .done(let summary):
            return .completed(MaintenanceReport(orphans: orphanReport, profiles: summary))
        }
    }

    /// 第 4 步的执行结果。抽成内部枚举是为了让「中途被打断」能原样冒泡成 `.aborted`，
    /// 而不是被吞进一个可选的摘要里。
    private enum ProfileSweepOutcome {
        case done(ProfileCleanupSummary)
        case aborted(stage: String, reason: String)
    }

    private func sweepStaleProfiles(token: UUID) async -> ProfileSweepOutcome {
        guard let profileSweeper else { return .done(ProfileCleanupSummary(stage: "skipped-not-wired")) }
        guard gate.shouldAbort(token) == false else {
            return .aborted(stage: "描述文件清理", reason: "用户操作已开始")
        }
        let summary: ProfileCleanupSummary
        do {
            let records = try await appStore.fetchAll()
            let keep = Self.profileKeepMap(
                records: records,
                sealProfileUUID: sealRunningProfileUUID?()
            )
            summary = await profileSweeper.sweepStaleProfiles(
                keepingByBundleID: keep,
                // 顺带回收「换 Apple ID 后旧 Team 后缀」留下的孤儿 profile（实测 39 个
                // Bundle ID 变体、33 份孤儿）。这条路径是**唯一**覆盖全部 Seal 管理 App
                // 的批量清理点，也是唯一能清掉「已从 Seal 列表删掉的 App」的地方 ——
                // 那种情况记录里没有 base 可比对，只有 `.seal.` 中缀规则能捞到。
                // 每一条都要过设备端核验（会抛错的 `isAppInstalled` + 阳性对照），
                // 见 `DeviceProfileCleaner.removeProfiles` 阶段 B。
                reclaimSealOrphans: true
            )
        } catch {
            // 读不到记录 ⇒ 保留集合不可信 ⇒ 什么都不删。绝不因为这一步失败就让整轮维护失败。
            summary = ProfileCleanupSummary(stage: "skipped-record-read-failed")
        }
        try? await logStore?.append(
            category: .system,
            message: "设备端旧描述文件清理：\(summary.logMessage)",
            code: "SEAL-PROFILE-320"
        )
        return .done(summary)
    }

    /// 构造「Bundle ID → 必须保留的 profile UUID」。
    ///
    /// 只收**有明确记录**的应用：`provisioningProfileUUID` 缺失或为空的整条跳过。
    /// 宁可留着旧 profile（只是占地方），也绝不能猜错 —— 删掉正在用的那一份会让
    /// 已安装的 App 立刻无法启动（iOS 启动时会校验 profile 是否还在设备上）。
    ///
    /// 扩展只在 `signedArtifactStatus == .installed` 时才进保留集合。原因：
    /// `SigningCoordinator.applySigningResult` 在**签名阶段**就会把扩展的 UUID 改成新产物的
    ///（不像顶层 profile 字段那样等安装校验通过），所以「签名成功但安装失败」时，
    /// 扩展记录指向的是一份设备上并不存在的 profile。拿它当保留集合，
    /// 会把真正在用的那一份删掉，扩展当场失效。
    static func profileKeepMap(records: [AppRecord], sealProfileUUID: String?) -> [String: String] {
        var map: [String: String] = [:]
        for record in records {
            guard let bundleID = record.mappedBundleIdentifier ?? record.preferredBundleIdentifier,
                  Self.isBlank(bundleID) == false else {
                continue
            }
            // 拿不到「当前在用的是哪一份」就整条跳过：宁可留着旧 profile（只是占地方），
            // 也绝不能猜错 —— 删掉正在用的那一份会让已安装的 App 立刻无法启动。
            guard let uuid = record.provisioningProfileUUID,
                  Self.isBlank(uuid) == false else {
                continue
            }
            map[bundleID] = uuid
            // 安装校验通过才说明 `extensions` 里的 UUID 就是设备上那一组。
            guard record.signedArtifactStatus == .installed else { continue }
            for extensionRecord in record.extensions {
                guard let extensionBundleID = extensionRecord.mappedBundleIdentifier,
                      Self.isBlank(extensionBundleID) == false,
                      let extensionUUID = extensionRecord.provisioningProfileUUID,
                      Self.isBlank(extensionUUID) == false else {
                    continue
                }
                map[extensionBundleID] = extensionUUID
            }
        }
        // Seal 自己：以运行时读到的真实 profile 覆盖记录值（记录可能落后于现实）。
        if let sealProfileUUID,
           Self.isBlank(sealProfileUUID) == false,
           let seal = records.first(where: { $0.isSeal }),
           let sealBundleID = seal.mappedBundleIdentifier ?? seal.preferredBundleIdentifier,
           Self.isBlank(sealBundleID) == false {
            map[sealBundleID] = sealProfileUUID
        }
        return map
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func unexpectedFailure(stage: String, error: Error) -> ImportFailure {
        let nsError = error as NSError
        return ImportFailure(
            title: "本地维护未完成",
            reason: "\(stage)遇到未预期错误，已停止本轮维护，未完成的步骤下次启动会继续。\n[\(nsError.domain) \(nsError.code)]",
            recovery: "下次打开 Seal 会自动继续",
            code: "SEAL-STORAGE-007"
        )
    }
}
