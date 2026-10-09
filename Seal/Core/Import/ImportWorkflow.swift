import Foundation

/// 一次导入要提交成什么。
///
/// 默认 `.newRecord`（新建一条待签名记录）—— 这也是「同一个 IPA 导入多个副本、
/// 用不同 Bundle ID 分别签名同时安装」那条路径的形态。
/// `.replaceInstalled` 是**覆盖更新**：用新导入的 IPA 替换一条**已安装**记录，
/// 由用户在导入确认页显式选择（判据见 `ImportReplacementPolicy`）。
enum ImportCommitTarget: Equatable, Sendable {
    case newRecord
    case replaceInstalled(appID: UUID)
}

actor ImportWorkflow {
    private(set) var state: ImportWorkflowState = .idle

    private let parser: IPAParserService
    private let fileStore: AppFileStore
    private let appStore: any AppStore
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    /// 当前**运行中**的 Seal 自身 Bundle ID。只服务一条兜底判据：
    /// 导入的 IPA 就是这个正在运行的 Seal 自己时，无论记录写成什么样都必须按
    /// 「自更新」处理（否则会新建一条 `isSeal == false` 的普通记录落到「待签名」页，
    /// 签名时又与已安装的 Seal 争同一个 Bundle ID 被 `SEAL-BUNDLE-004` 拦下）。
    private let runningSealBundleIdentifier: String?
    private var retryDraft: ImportDraft?
    /// 重试时必须沿用**同一个**提交目标：用户已经确认过「覆盖更新」，
    /// 重试却悄悄变回「新建」会让两条记录争同一个签名身份。
    private var retryTarget: ImportCommitTarget = .newRecord
    private(set) var lastCleanupFailure: ImportFailure?

    init(
        parser: IPAParserService,
        fileStore: AppFileStore,
        appStore: any AppStore,
        runningSealBundleIdentifier: String? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.parser = parser
        self.fileStore = fileStore
        self.appStore = appStore
        self.runningSealBundleIdentifier = runningSealBundleIdentifier
        self.now = now
        self.makeID = makeID
    }

    func prepare(sourceURL: URL) async {
        guard canPrepare else { return }
        await discardRetryDraft()
        if let cleanupFailure = lastCleanupFailure {
            state = .failed(cleanupFailure)
            return
        }
        state = .preparing

        var stagedIPA: StagedIPA?
        do {
            let staged = try await fileStore.stage(sourceURL: sourceURL)
            stagedIPA = staged
            try Task.checkCancellation()
            let parsed = try parser.parse(url: staged.url)
            // 版本检查：找同 Bundle ID 的已存在记录，比较版本
            let versionCheck = await checkVersion(parsed: parsed, stagedURL: staged.url)
            let draft = ImportDraft(
                appID: makeID(),
                parsedIPA: parsed,
                stagedIPA: staged,
                versionCheck: versionCheck
            )
            state = .awaitingConfirmation(draft)
        } catch is CancellationError {
            if let stagedIPA, let cleanupFailure = await cancelStagedIPA(stagedIPA) {
                state = .failed(cleanupFailure)
            } else {
                state = .idle
            }
        } catch {
            let importFailure = Self.importFailure(from: error)
            if let stagedIPA, let cleanupFailure = await cancelStagedIPA(stagedIPA) {
                state = .failed(cleanupFailure)
            } else {
                state = .failed(importFailure)
            }
        }
    }

    /// 版本检查：比较新 IPA 与已存在记录的版本
    /// - 高版本 → .upgrade（直接覆盖）
    /// - 同版本同内容 → .alreadyLatest（阻止导入）
    /// - 同版本不同构建号 → .buildUpgrade / .buildDowngrade（按构建号比）
    /// - 同版本同构建号不同内容 → .sameVersionDifferentContent（需确认，可能被修改过）
    /// - 低版本 → .downgrade（需二次确认）
    private func checkVersion(parsed: ParsedIPA, stagedURL: URL) async -> VersionCheckResult {
        guard let records = try? await appStore.fetchAll() else {
            return .newApp
        }
        // 找同 Bundle ID 的已存在记录（包括 Seal 自更新）
        let existing = Self.existingSealRecord(
            for: parsed,
            in: records,
            runningSealBundleIdentifier: runningSealBundleIdentifier
        ) ?? records.first { record in
            record.isSeal == false
                && record.originalBundleIdentifier == parsed.bundleIdentifier
        }
        guard let existing else {
            return .newApp
        }

        let oldVersion = existing.version ?? ""
        let newVersion = parsed.version ?? ""
        let comparison = Self.compareVersions(newVersion, oldVersion)

        if comparison > 0 {
            return .upgrade(oldVersion: oldVersion, newVersion: newVersion)
        } else if comparison < 0 {
            return .downgrade(oldVersion: oldVersion, newVersion: newVersion)
        } else {
            // 营销版本相同：比构建号
            let oldBuild = existing.buildNumber ?? ""
            let newBuild = parsed.buildNumber ?? ""
            let buildComparison = Self.compareBuildNumbers(newBuild, oldBuild)
            if buildComparison > 0 {
                return .buildUpgrade(oldBuild: oldBuild, newBuild: newBuild, version: newVersion)
            } else if buildComparison < 0 {
                return .buildDowngrade(oldBuild: oldBuild, newBuild: newBuild, version: newVersion)
            }
            // 构建号也相同：比较内容指纹
            let newFingerprint = try? AppFileStore.streamingSHA256(url: stagedURL)
            // 找旧 IPA 文件路径（空壳记录的 ipaRelativePath 为空，直接跳过）
            if !existing.ipaRelativePath.isEmpty,
               let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let oldURL = docs.appendingPathComponent(existing.ipaRelativePath)
                let oldFingerprint = try? AppFileStore.streamingSHA256(url: oldURL)
                if let newFP = newFingerprint, let oldFP = oldFingerprint, newFP == oldFP {
                    return .alreadyLatest(version: newVersion)
                }
            }
            // 指纹不同或无法比较 → 视为内容不同（可能被修改过）
            return .sameVersionDifferentContent(version: newVersion)
        }
    }

    /// 构建号比较：纯数字按数值比，否则按字符串比。返回 >0 表示 b1 > b2。
    private static func compareBuildNumbers(_ b1: String, _ b2: String) -> Int {
        if let n1 = Int(b1), let n2 = Int(b2) {
            return n1 == n2 ? 0 : (n1 > n2 ? 1 : -1)
        }
        return b1.compare(b2).rawValue
    }

    /// 版本号比较：返回 >0 表示 v1 > v2，<0 表示 v1 < v2，=0 表示相等
    /// 问题12修复：统一走 Version.compare，避免两套实现行为不一致（v 前缀处理）。
    private static func compareVersions(_ v1: String, _ v2: String) -> Int {
        switch Version.compare(v1, v2) {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }

    func confirm(
        preferredDraft: ImportDraft? = nil,
        target: ImportCommitTarget = .newRecord
    ) async {
        switch state {
        case .awaitingConfirmation(let draft):
            await commit(draft, target: target)
        case .failed, .idle, .completed:
            guard let preferredDraft else { return }
            await commit(preferredDraft, target: target)
        case .preparing, .committing:
            return
        }
    }

    func retry() async {
        guard case .failed = state, let draft = retryDraft else { return }
        state = .awaitingConfirmation(draft)
        await commit(draft, target: retryTarget)
    }

    func cancel() async {
        let draft: ImportDraft?
        switch state {
        case .awaitingConfirmation(let current), .committing(let current):
            draft = current
        case .failed:
            draft = retryDraft
        default:
            draft = nil
        }

        if let draft, let cleanupFailure = await cancelStagedIPA(draft.stagedIPA) {
            retryDraft = nil
            state = .failed(cleanupFailure)
            return
        }
        retryDraft = nil
        state = .idle
    }

    private var canPrepare: Bool {
        switch state {
        case .idle, .completed, .failed:
            return true
        case .preparing, .awaitingConfirmation, .committing:
            return false
        }
    }

    private func commit(_ draft: ImportDraft, target: ImportCommitTarget) async {
        state = .committing(draft)
        var fileTransaction: PreparedAppFileTransaction?
        var databaseReplacedRecords: [AppRecord] = []
        var databaseRecord: AppRecord?

        do {
            let records = try await appStore.fetchAll()
            let existingSeal = Self.existingSealRecord(
                for: draft.parsedIPA,
                in: records,
                runningSealBundleIdentifier: runningSealBundleIdentifier
            )
            // 覆盖更新的目标**当场复核**：用户在导入确认页停留期间记录可能已被删除、
            // 或已不再是已安装状态 ⇒ 复核不过就回落「新建」，绝不把别的记录覆盖掉。
            //
            // ⚠️ 默认仍是「新建」：同一个 IPA 允许导入多个副本、用不同 Bundle ID
            // 签名后同时安装，那条路径上的记录都是待签名状态，不能被替换掉。
            let existing: AppRecord?
            switch target {
            case .newRecord:
                existing = nil
            case .replaceInstalled(let appID):
                existing = ImportReplacementPolicy.confirmedReplacement(
                    appID: appID,
                    for: draft.parsedIPA,
                    in: records
                )
            }
            let preferenceSource = Self.preferenceSource(
                for: draft.parsedIPA,
                in: records,
                excluding: existing?.id
            )
            // 文件目录键必须与记录 id 一致：`AppFileStore` 用 appID 同时决定
            // `Apps/<appID>/` 目录名与写进记录里的相对路径（`Original.ipa` / `Signed.ipa`），
            // 两者不一致时签名阶段会去一个不存在的目录取包。覆盖更新复用 `existing.id`
            // ⇒ 这里必须用同一个 id（否则覆盖后签名必然找不到源包）。
            let commitAppID = existingSeal?.id ?? existing?.id ?? draft.appID
            let preferredIconData: Data?
            if let path = existingSeal?.preferredIconRelativePath
                ?? existingSeal?.iconRelativePath
                ?? existing?.preferredIconRelativePath
                ?? existing?.iconRelativePath
                ?? preferenceSource?.preferredIconRelativePath {
                preferredIconData = try? await fileStore.read(relativePath: path)
            } else {
                preferredIconData = nil
            }

            var transaction = try await fileStore.prepareImportCommit(
                staged: draft.stagedIPA,
                appID: commitAppID,
                iconData: draft.parsedIPA.iconData,
                preferredIconData: preferredIconData
            )
            fileTransaction = transaction
            transaction = try await fileStore.markDatabaseCommitPending(transaction)
            fileTransaction = transaction

            // 自更新源指纹：只有导入 Seal 自身 IPA 时才算 —— 续签准入靠它判断
            // 「有没有待安装的更新源」。版本号相同时只能靠内容指纹区分
            // （`ProfileOnlyRenewalPolicy.hasPendingUpdateSource`）。
            //
            // ⚠️ 必须对 `draft.stagedIPA`（用户选的源包）做哈希：
            // `transaction.storedFiles.ipaRelativePath` 指向最终路径，而新包此时还在
            // pending 目录里、尚未落盘 —— 对最终路径哈希会算到**旧包**头上
            // （2026-10-02 CI 实测 `importingSealIPAWithSameVersionRecordsSourceFingerprint` 失败）。
            // 流式哈希，不整包进内存；失败不阻断导入（回落为纯版本比较）。
            let pendingUpdateSourceFingerprint: String?
            if let existing = existingSeal {
                let newFingerprint = try? AppFileStore.streamingSHA256(url: draft.stagedIPA.url)
                // 与已装包指纹一致 ⇒ 同一个包，不标为待更新
                if let newFP = newFingerprint,
                   let installedFP = existing.installedFingerprint,
                   newFP == installedFP {
                    pendingUpdateSourceFingerprint = nil
                } else if existing.installedFingerprint == nil {
                    // 老记录没有指纹（旁加载装的）：比构建号，导入包与运行包构建号一致 ⇒ 同一个包
                    let importedBuild = draft.parsedIPA.buildNumber
                    let runningBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                    if let rb = runningBuild, importedBuild == rb {
                        pendingUpdateSourceFingerprint = nil
                    } else {
                        pendingUpdateSourceFingerprint = newFingerprint
                    }
                } else {
                    pendingUpdateSourceFingerprint = newFingerprint
                }
            } else if let existing {
                // 非 Seal 覆盖更新：同样计算指纹，用于已安装列表标签（与 Seal 行为一致）。
                // 与已装包指纹一致 ⇒ 同一个包，不标为待更新。
                let newFingerprint = try? AppFileStore.streamingSHA256(url: draft.stagedIPA.url)
                if let newFP = newFingerprint,
                   let installedFP = existing.installedFingerprint,
                   newFP == installedFP {
                    pendingUpdateSourceFingerprint = nil
                } else {
                    pendingUpdateSourceFingerprint = newFingerprint
                }
            } else {
                pendingUpdateSourceFingerprint = nil
            }

            var record = Self.makeRecord(
                draft: draft,
                files: transaction.storedFiles,
                importedAt: now(),
                replacing: existing,
                existingSeal: existingSeal,
                preferenceSource: preferenceSource,
                pendingUpdateSourceFingerprint: pendingUpdateSourceFingerprint
            )
            record.pendingFileTransactionID = transaction.id
            // 被替换的记录必须逐条记下来，回滚时按 id 恢复：
            // 自更新替换的是 Seal 自己的记录，覆盖更新替换的是那条已安装记录。
            databaseReplacedRecords = [existingSeal, existing].compactMap { $0 }
            try await appStore.save(record)
            databaseRecord = record

            transaction = try await fileStore.finalizeImportCommit(transaction)
            fileTransaction = transaction

            record.pendingFileTransactionID = nil
            try await appStore.save(record)
            databaseRecord = record
            try await fileStore.completeImportCommit(transaction)
            fileTransaction = nil

            lastCleanupFailure = await cancelStagedIPA(draft.stagedIPA)
            // Replaced pending-import directories are intentionally left for the
            // orphan maintenance pass. Deleting them here would introduce a new
            // post-commit failure point after the authoritative DB/file transaction
            // has already succeeded. Recovery also refuses to resurrect a second
            // record with the same original Bundle ID.
            retryDraft = nil
            state = .completed(record)
        } catch is CancellationError {
            if let rollbackFailure = await rollbackFailedCommit(
                transaction: fileTransaction,
                databaseRecord: databaseRecord,
                replacedRecords: databaseReplacedRecords
            ) {
                retryDraft = nil
                state = .failed(rollbackFailure)
            } else {
                retryDraft = nil
                state = .awaitingConfirmation(draft)
            }
        } catch {
            let originalFailure: ImportFailure
            if fileTransaction?.phase == .databaseCommitPending, databaseRecord == nil {
                originalFailure = Self.persistenceFailure
            } else {
                originalFailure = Self.importFailure(from: error)
            }
            if let transaction = fileTransaction,
               transaction.phase == .finalized {
                // A finalized transaction is intentionally left journaled when a
                // later metadata write fails. Startup recovery can safely finish it.
                retryDraft = nil
                state = .failed(Self.finalizeRecoveryFailure(originalFailure))
                return
            }

            if let rollbackFailure = await rollbackFailedCommit(
                transaction: fileTransaction,
                databaseRecord: databaseRecord,
                replacedRecords: databaseReplacedRecords
            ) {
                retryDraft = nil
                state = .failed(rollbackFailure)
            } else {
                retryDraft = draft
                retryTarget = target
                state = .failed(originalFailure)
            }
        }
    }


    private func rollbackFailedCommit(
        transaction: PreparedAppFileTransaction?,
        databaseRecord: AppRecord?,
        replacedRecords: [AppRecord]
    ) async -> ImportFailure? {
        if let databaseRecord {
            do {
                try await restoreDatabaseAfterFailedImport(
                    newRecordID: databaseRecord.id,
                    replacedRecords: replacedRecords
                )
            } catch {
                // Keep the file transaction journal intact. Startup recovery can
                // inspect the committed database/file state instead of losing the
                // only durable marker for this interrupted operation.
                return Self.rollbackRecoveryFailure
            }
        }

        if let transaction {
            do {
                try await fileStore.abortImportCommit(transaction)
            } catch {
                return Self.rollbackRecoveryFailure
            }
        }
        return nil
    }

    private func restoreDatabaseAfterFailedImport(
        newRecordID: UUID,
        replacedRecords: [AppRecord]
    ) async throws {
        try await appStore.delete(id: newRecordID)
        for record in replacedRecords {
            try await appStore.save(record)
        }
    }

    private func discardRetryDraft() async {
        lastCleanupFailure = nil
        if let retryDraft {
            lastCleanupFailure = await cancelStagedIPA(retryDraft.stagedIPA)
        }
        retryDraft = nil
        retryTarget = .newRecord
    }

    private func cancelStagedIPA(_ stagedIPA: StagedIPA) async -> ImportFailure? {
        do {
            try await fileStore.cancel(stagedIPA)
            return nil
        } catch {
            return Self.temporaryCleanupFailure
        }
    }

    func takeCleanupFailure() -> ImportFailure? {
        defer { lastCleanupFailure = nil }
        return lastCleanupFailure
    }

    private static func makeRecord(
        draft: ImportDraft,
        files: StoredAppFiles,
        importedAt: Date,
        replacing existing: AppRecord?,
        existingSeal: AppRecord?,
        preferenceSource: AppRecord?,
        pendingUpdateSourceFingerprint: String? = nil
    ) -> AppRecord {
        if let existingSeal {
            return makeSelfUpdateRecord(
                draft: draft,
                files: files,
                existingSeal: existingSeal,
                pendingUpdateSourceFingerprint: pendingUpdateSourceFingerprint
            )
        }

        // 覆盖更新：`existing` 是**已安装**记录 ⇒ 保留签名身份、清空旧版签名产物。
        // 这与下面「替换待签名记录」（`existing?.id ?? draft.appID` 那段）语义不同：
        // 那条路径要重置签名状态，这条路径必须**保住**它。
        if let existing, existing.belongsInInstalledList {
            return makeInstalledUpdateRecord(
                draft: draft,
                files: files,
                existing: existing,
                pendingUpdateSourceFingerprint: pendingUpdateSourceFingerprint
            )
        }

        let parsed = draft.parsedIPA
        let recordID = existing?.id ?? draft.appID
        // 导入时保留原始 Bundle ID，不继承之前签名记录的 mappedBundleIdentifier
        // 只有替换已存在的待签名记录时才保留用户设置的 preferredBundleIdentifier
        // 打开签名抽屉时才生成推荐的随机后缀 Bundle ID
        let preferredBundleIdentifier = existing?.preferredBundleIdentifier
        let preferredDisplayName = existing?.preferredDisplayName
            ?? preferenceSource?.preferredDisplayName
        let preferredIconRelativePath = existing?.preferredIconRelativePath
            ?? files.preferredIconRelativePath
        let iconRelativePath = files.iconRelativePath
            ?? existing?.iconRelativePath
        let removedExtensionBundleIdentifiers = existing?.removedExtensionBundleIdentifiers
            ?? preferenceSource?.removedExtensionBundleIdentifiers
            ?? []
        let isPinned = existing?.isPinned ?? false

        return AppRecord(
            id: recordID,
            originalBundleIdentifier: parsed.bundleIdentifier,
            mappedBundleIdentifier: nil,
            name: parsed.name,
            version: parsed.version,
            buildNumber: parsed.buildNumber,
            size: parsed.fileSize,
            iconRelativePath: iconRelativePath,
            state: .preflightPassed,
            expiryDate: nil,
            accountID: nil,
            certificateSerialNumber: nil,
            removedExtensionBundleIdentifiers: removedExtensionBundleIdentifiers,
            ipaRelativePath: files.ipaRelativePath,
            signedIPARelativePath: nil,
            preferredBundleIdentifier: preferredBundleIdentifier,
            preferredDisplayName: preferredDisplayName,
            preferredIconRelativePath: preferredIconRelativePath,
            isSeal: false,
            isPinned: isPinned,
            importedAt: importedAt,
            extensions: parsed.extensions,
            importWarnings: parsed.importWarnings
        )
    }

    /// Seal 自更新：新 IPA 作为一条**待签名**记录（`.imported`）进入待签名列表，
    /// 不再复用已安装记录。用户在待签名页签名，成功后替换旧记录。
    /// 2026-10-09 重设计：与其它 IPA 覆盖更新走同一套流程，不再特殊标记。
    private static func makeSelfUpdateRecord(
        draft: ImportDraft,
        files: StoredAppFiles,
        existingSeal: AppRecord,
        pendingUpdateSourceFingerprint: String? = nil
    ) -> AppRecord {
        let parsed = draft.parsedIPA
        return AppRecord(
            // 新 ID：待签名列表里的一条独立记录
            originalBundleIdentifier: parsed.bundleIdentifier,
            mappedBundleIdentifier: existingSeal.mappedBundleIdentifier,
            name: parsed.name,
            version: parsed.version,
            buildNumber: parsed.buildNumber,
            size: parsed.fileSize,
            iconRelativePath: files.iconRelativePath ?? existingSeal.iconRelativePath,
            state: .imported,
            accountID: existingSeal.accountID,
            signingTeamID: existingSeal.signingTeamID,
            ipaRelativePath: files.ipaRelativePath,
            preferredBundleIdentifier: existingSeal.preferredBundleIdentifier
                ?? existingSeal.mappedBundleIdentifier,
            preferredDisplayName: existingSeal.preferredDisplayName,
            preferredIconRelativePath: files.preferredIconRelativePath
                ?? existingSeal.preferredIconRelativePath,
            isSeal: true,
            isPinned: true,
            importedAt: Date(),
            extensions: parsed.extensions,
            replacesInstalledAppID: existingSeal.id
        )
    }

    /// 覆盖更新：用新导入的 IPA 替换一条**已安装**记录。
    ///
    /// 与「替换待签名记录」的关键差别是**保留签名身份**：`mappedBundleIdentifier` /
    /// 账号 / 证书 / 描述文件字段全部沿用，这样 `BundleIDPolicy.targetBundleIdentifier`
    /// 算出来的目标 ID 不变 ⇒ installd 覆盖设备上同一个 App，而不是并存第二个。
    /// 同时它让 `belongsInInstalledList` 保持为真 ⇒ `AppsViewModel.runSigning` 里
    /// `forceResign: forceResign || isRenewal` 为真 ⇒ 走完整重签并**免掉免费账号 3-app 预检**
    ///（`SigningCoordinator.isInstalledRenewal`）。
    ///
    /// 🔴 必须清空 `signedIPARelativePath` / `signedIPASHA256` / `signedArtifactStatus`：
    /// 它们描述的是**旧版本**的签名产物，留着会让「复用已签名包直接安装」那条路径
    /// 把旧版本装回设备（用户会以为「更新没生效」）。
    /// 覆盖更新：新 IPA 作为一条**待签名**记录（`.imported`）进入待签名列表，
    /// 不再复用已安装记录。用户在待签名页签名，成功后替换旧记录。
    /// 2026-10-09 重设计：与 Seal 自更新走同一套流程。
    private static func makeInstalledUpdateRecord(
        draft: ImportDraft,
        files: StoredAppFiles,
        existing: AppRecord,
        pendingUpdateSourceFingerprint: String? = nil
    ) -> AppRecord {
        let parsed = draft.parsedIPA
        return AppRecord(
            // 新 ID：待签名列表里的一条独立记录
            originalBundleIdentifier: parsed.bundleIdentifier,
            mappedBundleIdentifier: existing.mappedBundleIdentifier,
            name: parsed.name,
            version: parsed.version,
            buildNumber: parsed.buildNumber,
            size: parsed.fileSize,
            iconRelativePath: files.iconRelativePath ?? existing.iconRelativePath,
            state: .imported,
            accountID: existing.accountID,
            signingTeamID: existing.signingTeamID,
            ipaRelativePath: files.ipaRelativePath,
            preferredBundleIdentifier: existing.preferredBundleIdentifier,
            preferredDisplayName: existing.preferredDisplayName,
            preferredIconRelativePath: files.preferredIconRelativePath
                ?? existing.preferredIconRelativePath,
            isSeal: false,
            isPinned: existing.isPinned,
            importedAt: Date(),
            extensions: parsed.extensions,
            importWarnings: parsed.importWarnings,
            extensionProfileStrategy: existing.extensionProfileStrategy,
            replacesInstalledAppID: existing.id
        )
    }

    private static func existingPendingImportRecord(
        for parsed: ParsedIPA,
        in records: [AppRecord]
    ) -> AppRecord? {
        records.first(where: { record in
            record.isSeal == false
                && record.originalBundleIdentifier == parsed.bundleIdentifier
                && record.hasSignedArtifact == false
                && AppState.replaceablePendingImportStates.contains(record.state)
        })
    }

    private static func existingSealRecord(
        for parsed: ParsedIPA,
        in records: [AppRecord],
        runningSealBundleIdentifier: String?
    ) -> AppRecord? {
        // ① 记录匹配（覆盖 original / mapped / preferred 三种写法）。
        if let matched = SelfAppRecordSelection.preferredExistingSealRecordForImportedIPA(
            in: records,
            importedBundleIdentifier: parsed.bundleIdentifier
        ) {
            return matched
        }
        // ② 兜底：导入包就是**当前正在运行的 Seal 自己**（Bundle ID 相同）⇒ 无论记录
        //    写成什么样都必须按自更新处理。否则会新建一条 `isSeal == false` 的普通记录
        //    落到「待签名」页，签名时又与已安装的 Seal 争同一个 Bundle ID 被拦下 ——
        //    用户看到的就是「连 Seal 自己都装不了」。
        guard let runningSealBundleIdentifier,
              ImportReplacementPolicy.normalizedBundleIdentifier(parsed.bundleIdentifier)
                == ImportReplacementPolicy.normalizedBundleIdentifier(runningSealBundleIdentifier)
        else { return nil }
        return records.first { $0.isSeal && $0.belongsInInstalledList }
            ?? records.first { $0.isSeal }
    }

    private static func preferenceSource(
        for parsed: ParsedIPA,
        in records: [AppRecord],
        excluding excludedID: UUID?
    ) -> AppRecord? {
        records
            .filter { record in
                record.id != excludedID
                    && record.isSeal == false
                    && record.originalBundleIdentifier == parsed.bundleIdentifier
                    && (record.lastSignedAt != nil || record.mappedBundleIdentifier != nil)
            }
            .max { lhs, rhs in
                (lhs.lastSignedAt ?? lhs.importedAt) < (rhs.lastSignedAt ?? rhs.importedAt)
            }
    }

    private static func importFailure(from error: Error) -> ImportFailure {
        if let failure = error as? ImportFailure {
            return failure
        }
        return ImportFailure(
            title: "无法导入 IPA",
            reason: "IPA 解析失败，文件结构或元数据不可读取。",
            recovery: "选择其他 IPA",
            code: "SEAL-IPA-200"
        )
    }

    private static let persistenceFailure = ImportFailure(
        title: "无法保存 IPA",
        reason: "应用记录保存失败（IPA 文件已就绪，但记录未能写入应用列表）。",
        recovery: "检查本机存储空间后重试",
        code: "SEAL-IPA-205"
    )

    private static let temporaryCleanupFailure = ImportFailure(
        title: "临时文件清理失败",
        reason: "导入产生的临时文件未能完整删除。",
        recovery: "稍后在存储维护中重试清理",
        code: "SEAL-STORAGE-003"
    )

    private static let rollbackRecoveryFailure = ImportFailure(
        title: "导入恢复未完成",
        reason: "本次导入未能完全回滚。Seal 已保留恢复记录，下次启动时会继续恢复。",
        recovery: "下次启动 Seal 会自动继续恢复，无需手动重试",
        code: "SEAL-IPA-ROLLBACK-001"
    )

    private static func finalizeRecoveryFailure(_ original: ImportFailure) -> ImportFailure {
        ImportFailure(
            title: "导入提交待恢复",
            reason: "IPA 文件已经提交，但后续状态保存未完成。Seal 已保留恢复记录，下次启动时会继续完成。",
            recovery: "下次启动 Seal 会自动继续完成，无需手动重试",
            code: original.code == "SEAL-IPA-205" ? "SEAL-IPA-213" : original.code
        )
    }
}
