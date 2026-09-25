import Foundation

actor AppRecordRecovery {
    private let appStore: any AppStore
    private let fileStore: AppFileStore
    private let parser: IPAParserService
    /// 已添加账号的读取口。只用来把扫回的记录挂回**同 Team 的账号**；
    /// 不传（测试 / 预览）时记录照建，只是 `accountID` 留空。
    private let accountsProvider: (@Sendable () async -> [AppleAccountRecord])?
    /// 设备端扫回的注入点。**默认 nil = 完全不扫** —— 见 `InstalledAppScanning`：
    /// `AppRecordRecoveryTests` 会直接调 `restoreMissingRecords()`，写死就会在 CI 的
    /// 模拟器上真的去调 `Provision.dumpProfiles`。
    private let deviceScanner: (any InstalledAppScanning)?

    init(
        appStore: any AppStore,
        fileStore: AppFileStore,
        parser: IPAParserService = IPAParserService(),
        accountsProvider: (@Sendable () async -> [AppleAccountRecord])? = nil,
        deviceScanner: (any InstalledAppScanning)? = nil
    ) {
        self.appStore = appStore
        self.fileStore = fileStore
        self.parser = parser
        self.accountsProvider = accountsProvider
        self.deviceScanner = deviceScanner
    }

    @discardableResult
    func restoreMissingRecords() async throws -> InstalledRecordRecoverySummary {
        try await recoverPendingFileTransactions()
        try await reconcileKnownRecords()

        let existing = try await appStore.fetchAll()
        let storedIPAs = try await fileStore.storedOriginalIPAs()
        for stored in storedIPAs {
            guard existing.contains(where: { $0.ipaRelativePath == stored.relativePath }) == false else {
                continue
            }
            guard let parsed = try? parser.parse(url: stored.url) else { continue }
            // Seal 由 SelfAppRegistrar 专门管理，通用恢复逻辑跳过，避免产生重复记录
            guard parsed.name != "Seal" else { continue }
            guard existing.contains(where: {
                $0.isSeal && Self.matchesSealBundleIdentifier(parsed.bundleIdentifier, record: $0)
            }) == false else {
                continue
            }
            // A leftover directory from an older replaced import must never be
            // resurrected as a second app record. Bundle identity, not the file
            // name, is the stable recovery key for third-party imports.
            guard existing.contains(where: {
                $0.isSeal == false
                    && $0.originalBundleIdentifier.caseInsensitiveCompare(
                        parsed.bundleIdentifier
                    ) == .orderedSame
            }) == false else {
                continue
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: stored.url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? parsed.fileSize
            let signedArtifact = try await recoveredSignedArtifact(appID: stored.appID)
            let record = AppRecord(
                id: stored.appID,
                originalBundleIdentifier: parsed.bundleIdentifier,
                mappedBundleIdentifier: signedArtifact?.mappedBundleIdentifier,
                name: parsed.name,
                version: parsed.version,
                buildNumber: parsed.buildNumber,
                size: size,
                iconRelativePath: nil,
                state: signedArtifact == nil ? .imported : .signed,
                expiryDate: nil,
                accountID: nil,
                ipaRelativePath: stored.relativePath,
                signedIPARelativePath: signedArtifact?.relativePath,
                signedIPASHA256: signedArtifact?.sha256,
                signedArtifactStatus: signedArtifact == nil ? nil : .awaitingVerification,
                preferredBundleIdentifier: signedArtifact?.mappedBundleIdentifier
                    ?? BundleIDPolicy.recommendedBundleIdentifier(for: parsed.bundleIdentifier),
                isPinned: false,
                importedAt: Date(),
                extensions: parsed.extensions
            )
            try await appStore.save(record)
        }

        // ── 设备端扫回（2026-09-25 新增）───────────────────────────────
        // 上面三步都只看得见**本地文件**；「只卸载了 Seal、其他 App 没卸载」的场景里
        // 本地文件全没了，唯一的痕迹在设备端的描述文件里。放在最后是因为它要读
        // 前两步刚修好的记录（「已覆盖的 Bundle ID」必须是最新的）。
        return await recoverRecordsFromDeviceProfiles()
    }

    /// 设备端扫回：把「设备上装着、记录里没有」的 Seal 签名应用补回已安装列表。
    ///
    /// 代价可控：**候选为空就直接返回**，常见情况（记录齐全）只花一次 profile dump，
    /// 不会给启动加一轮设备查询。有候选时先做**阳性对照**（拿 Seal 自己问），
    /// 对照不过或任何一条查询抛错都**整轮中止、一条记录都不建** —— 与
    /// `reconcileInstalledAppsWithDevice` 的「先问完再动手」是同一条纪律。
    private func recoverRecordsFromDeviceProfiles() async -> InstalledRecordRecoverySummary {
        var summary = InstalledRecordRecoverySummary()
        // 没接线就**完全不碰设备**（测试 / 预览走这里）。`skipped-not-wired` 必须与
        // `skipped-no-candidates` 分得开 —— 前者是「没人接这根线」（配置问题），
        // 后者是「接了线、设备端确实没有可补的」（正常结论）。
        guard let deviceScanner else {
            summary.stage = "skipped-not-wired"
            return summary
        }
        // 先 dump（候选只能从它推出来）；拿不到就整轮结束 —— 「读不到」绝不能当成
        // 「设备上没有」，否则扫回会静默失效，用户永远等不到他的应用回来。
        guard let profiles = await deviceScanner.scanProfileSummaries() else {
            summary.stage = "skipped-dump-unavailable"
            return summary
        }
        let records = (try? await appStore.fetchAll()) ?? []
        var accounts: [AppleAccountRecord] = []
        if let accountsProvider {
            accounts = await accountsProvider()
        }
        let context = InstalledRecordRecoveryPolicy.context(
            records: records,
            accountTeamIdentifiers: Set(accounts.map(\.teamID)),
            dismissedBundleIdentifiers: DismissedInstalledRecordTombstones.all(),
            sealCanonicalBundleIdentifier: BundleIDPolicy.canonicalSealBundleIdentifier()
        )
        let drafts = InstalledRecordRecoveryPolicy.drafts(profiles: profiles, context: context)
        summary.candidates = drafts.count
        summary.samples = drafts.prefix(3).map(\.bundleIdentifier)
        // 候选为空 ⇒ **一次设备查询都不发**（常见情况：记录齐全，只多花一次 dump）。
        guard drafts.isEmpty == false else {
            summary.stage = "skipped-no-candidates"
            return summary
        }
        // 阳性对照 + 逐条核验，**先问完再动手**。
        guard let confirmed = await deviceScanner.scanConfirmedInstalledBundleIdentifiers(
            candidates: drafts.map(\.bundleIdentifier),
            positiveControl: Bundle.main.bundleIdentifier
        ) else {
            summary.stage = "skipped-channel-unavailable"
            return summary
        }
        for draft in drafts {
            let accountID = accounts.first {
                $0.teamID.caseInsensitiveCompare(draft.teamIdentifier) == .orderedSame
            }?.id
            guard let record = InstalledRecordRecoveryPolicy.makeRecord(
                from: draft,
                installedOnDevice: confirmed.contains(
                    InstalledRecordRecoveryPolicy.normalizedBundleIdentifier(draft.bundleIdentifier)
                ),
                accountID: accountID
            ) else {
                summary.notInstalled += 1
                continue
            }
            do {
                try await appStore.save(record)
                summary.recovered += 1
            } catch {
                let nsError = error as NSError
                summary.stage = "failed-save"
                summary.firstError = "\(nsError.domain) \(nsError.code)"
                break
            }
        }
        return summary
    }

    private func recoverPendingFileTransactions() async throws {
        let transactions = try await fileStore.pendingImportTransactions()
        guard transactions.isEmpty == false else { return }

        var records = try await appStore.fetchAll()
        var failedTransactionCount = 0
        for transaction in transactions {
            let matchingRecord = records.first { $0.pendingFileTransactionID == transaction.id }

            if matchingRecord != nil || transaction.phase == .finalized {
                do {
                    let finalized = transaction.phase == .finalized
                        ? transaction
                        : try await fileStore.finalizeImportCommit(transaction)
                    if var record = matchingRecord {
                        record.pendingFileTransactionID = nil
                        try await appStore.save(record)
                        if let index = records.firstIndex(where: { $0.id == record.id }) {
                            records[index] = record
                        }
                    }
                    try await fileStore.completeImportCommit(finalized)
                } catch {
                    // Leave the journal intact so a later launch can retry.
                    failedTransactionCount += 1
                }
            } else {
                do {
                    try await fileStore.abortImportCommit(transaction)
                } catch {
                    failedTransactionCount += 1
                }
            }
        }

        if failedTransactionCount > 0 {
            throw ImportFailure(
                title: "本地事务恢复未完成",
                reason: "有 \(failedTransactionCount) 个 IPA 文件事务仍需恢复，恢复记录已保留。",
                recovery: "下次启动 Seal 会自动继续恢复",
                code: "SEAL-IPA-214"
            )
        }
    }

    private func reconcileKnownRecords() async throws {
        var records = try await appStore.fetchAll()
        for index in records.indices {
            var record = records[index]
            guard let signedPath = record.signedIPARelativePath else { continue }
            let exists = try await fileStore.exists(relativePath: signedPath)
            if exists == false {
                record.signedArtifactStatus = .missing
                if record.state != .installed && record.isSeal == false {
                    record.state = .signed
                }
                try await appStore.save(record)
                records[index] = record
                continue
            }

            do {
                let hash = try await fileStore.sha256(relativePath: signedPath)
                if let expected = record.signedIPASHA256,
                   expected.caseInsensitiveCompare(hash) != .orderedSame {
                    record.signedArtifactStatus = .damaged
                } else {
                    // Legacy signed packages gain integrity metadata during migration.
                    record.signedIPASHA256 = hash
                    if record.signedArtifactStatus == nil
                        || record.signedArtifactStatus == .missing
                        || record.signedArtifactStatus == .damaged {
                        record.signedArtifactStatus = record.state == .installed ? .installed : .available
                    }
                }
                try await appStore.save(record)
                records[index] = record
            } catch {
                record.signedArtifactStatus = .damaged
                if record.state != .installed && record.isSeal == false {
                    record.state = .signed
                }
                try await appStore.save(record)
                records[index] = record
            }
        }
    }

    private struct RecoveredSignedArtifact {
        let relativePath: String
        let sha256: String
        let mappedBundleIdentifier: String?
    }

    private func recoveredSignedArtifact(appID: UUID) async throws -> RecoveredSignedArtifact? {
        guard let signed = try await fileStore.storedSignedIPA(appID: appID) else { return nil }
        let hash = try await fileStore.sha256(relativePath: signed.relativePath)
        let mappedBundleIdentifier = (try? parser.parse(url: signed.url))?.bundleIdentifier
        return RecoveredSignedArtifact(
            relativePath: signed.relativePath,
            sha256: hash,
            mappedBundleIdentifier: mappedBundleIdentifier
        )
    }

    private static func matchesSealBundleIdentifier(
        _ bundleIdentifier: String,
        record: AppRecord
    ) -> Bool {
        bundleIdentifier == record.originalBundleIdentifier
            || bundleIdentifier == record.mappedBundleIdentifier
    }
}
