import Foundation
import ZIPFoundation

actor SelfAppRegistrar {
    private let metadata: SelfAppMetadata
    private let appStore: any AppStore
    private let accountRepository: any AccountRepository
    private let fileStore: AppFileStore
    private let selfReplacement: (any SelfReplacing)?
    private let profileCleaner: (any SelfReplacementProfileCleaning)?
    private let keychain: KeychainVault?
    private let logStore: SealLogStore?

    // 固定 ID，确保 Seal 记录和文件夹路径始终一致，不会出现多个文件夹
    private let fixedSealID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    // 防重入：确保同时只有一个注册流程在执行
    private var isRegistering = false

    init(
        metadata: SelfAppMetadata,
        appStore: any AppStore,
        accountRepository: any AccountRepository,
        fileStore: AppFileStore,
        selfReplacement: (any SelfReplacing)? = nil,
        profileCleaner: (any SelfReplacementProfileCleaning)? = nil,
        keychain: KeychainVault? = nil,
        logStore: SealLogStore? = nil
    ) {
        self.metadata = metadata
        self.appStore = appStore
        self.accountRepository = accountRepository
        self.fileStore = fileStore
        self.selfReplacement = selfReplacement
        self.profileCleaner = profileCleaner
        self.keychain = keychain
        self.logStore = logStore
    }

    func ensureRegistered() async throws {
        guard isRegistering == false else { return }
        isRegistering = true
        defer { isRegistering = false }

        var records = try await appStore.fetchAll()
        let accounts = try await accountRepository.fetchAll()
        var existing = SelfAppRecordSelection.preferredExistingSealRecord(
            in: records,
            currentBundleIdentifier: metadata.bundleIdentifier
        )

        // 启动只对账上一进程留下的自替换事务，绝不在这里发起安装。
        // 结算会推进记录，之后必须重新读取，避免旧快照覆盖刚确认的真实身份。
        if try await reconcileSelfReplacement(
            existing: existing,
            accounts: accounts,
            // 传全部记录（不只是 Seal 那条）：结算清理的保留集合只有 Seal 自己一个条目，
            // 宽松受保护集合必须由**全部**记录算出来，否则其它 App 的扩展会被当孤儿删掉。
            allRecords: records
        ) {
            records = try await appStore.fetchAll()
            existing = SelfAppRecordSelection.preferredExistingSealRecord(
                in: records,
                currentBundleIdentifier: metadata.bundleIdentifier
            )
        }

        // 已导入、待下次安装生效的自更新源（hasPendingSelfUpdateSource）：
        // 其版本通常比当前运行中的 Bundle 新。此窗口内 App 若重启，仍运行旧版，
        // 绝不能用当前旧 metadata 覆盖这条待安装记录与文件，否则更新源丢失。
        // 仅当待安装源文件仍在、且记录版本不低于运行版本时保留（记录版本更低说明
        // 待安装源已被外部更新取代，属残留标记，落到原子更新对齐当前运行版本，
        // 否则已安装列表会一直显示旧版本号）。
        if let existing,
           existing.hasPendingSelfUpdateSource,
           existing.ipaRelativePath.isEmpty == false,
           try await fileStore.exists(relativePath: existing.ipaRelativePath),
           Version.compare(existing.version, metadata.version) != .orderedAscending {
            // 保留待安装源及 signingTargets，但已安装快照必须来自当前运行包。
            // 安装失败后仍运行旧包时，不能让安装前乐观写入的新有效期继续显示。
            try await reconcileSealRecordFromRunningBundleIfNeeded(
                existing: existing,
                metadata: metadata,
                accounts: accounts
            )
            try await cleanupDuplicateSealRecords(records: records, keepID: existing.id)
            return
        }

        // 版本一致且文件存在 → 直接跳过，只清理重复记录
        if let existing,
           existing.version == metadata.version,
           existing.buildNumber == metadata.buildNumber,
           existing.ipaRelativePath.isEmpty == false,
           try await fileStore.exists(relativePath: existing.ipaRelativePath) {
            try await cleanupDuplicateSealRecords(records: records, keepID: existing.id)
            // 版本一致也回补：Team/账号（首次未记录时从自身描述文件补全，避免续签时退化成
            // "选第一个账号"导致 Bundle ID 被占用），**以及 profile 身份与有效期**。
            // 后者是 R07：同版本续签会换掉 profile 但版本号不变，只比版本就会漏掉结算。
            try await reconcileSealRecordFromRunningBundleIfNeeded(
                existing: existing,
                metadata: metadata,
                accounts: accounts
            )
            return
        }

        // 版本变更或文件缺失 → 原子更新
        let id = existing?.id ?? fixedSealID
        try await atomicallyUpdateSealRecord(id: id, existing: existing, accounts: accounts)

        // 清理历史残留的重复记录
        try await cleanupDuplicateSealRecords(records: records, keepID: id)
    }

    // MARK: - 原子更新：先暂存，再提交覆盖，失败回滚

    private func atomicallyUpdateSealRecord(
        id: UUID,
        existing: AppRecord?,
        accounts: [AppleAccountRecord]
    ) async throws {
        // 1. 打包新 IPA 到临时工作区（不碰旧文件）
        let workspace = try await fileStore.signingWorkspace(appID: UUID())
        defer { try? FileManager.default.removeItem(at: workspace) }

        let payload = workspace.appending(path: "Payload", directoryHint: .isDirectory)
        let appURL = payload.appending(
            path: "\(metadata.name).app",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: payload,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: metadata.bundleURL, to: appURL)
        let ipaURL = workspace.appending(path: "Seal.ipa")
        try FileManager.default.zipItem(
            at: payload,
            to: ipaURL,
            shouldKeepParent: true,
            compressionMethod: .deflate
        )

        // 2. 暂存新文件
        let staged = try await fileStore.stage(sourceURL: ipaURL)

        do {
            // 3. 图标：优先用新提取的，失败则复用旧图标
            var iconData = metadata.iconData
            if iconData == nil, let oldIconPath = existing?.iconRelativePath {
                iconData = try? await fileStore.read(relativePath: oldIconPath)
            }

            // 4. 提交新文件（用同一个 ID，覆盖旧文件，不是先删后建）
            let files = try await fileStore.commit(
                staged: staged,
                appID: id,
                iconData: iconData
            )

            // 5. 取消暂存
            do {
                try await fileStore.cancel(staged)
            } catch {
                throw ImportFailure(
                    title: "Seal 临时文件清理失败",
                    reason: "Seal 自身注册已写入文件，但暂存文件未能清理。",
                    recovery: "稍后在设置→存储维护中重试清理",
                    code: "SEAL-STORAGE-SELF-001"
                )
            }

            // 6. 计算文件大小
            let attributes = try FileManager.default.attributesOfItem(atPath: ipaURL.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0

            // 7. 解析账户绑定（和以前逻辑一致，匹配不到返回 nil，不强制用第一个账户）
            let resolvedAccountID = SelfAppAccountBinding.resolvedAccountID(
                teamIdentifier: metadata.signingTeamIdentifier,
                accounts: accounts,
                fallbackAccountID: existing?.accountID
            )

            // 8. 更新记录（复用 ID，不删除重建）
            let record = AppRecord(
                id: id,
                originalBundleIdentifier: SelfAppBundleIdentity.originalBundleIdentifier(
                    currentBundleIdentifier: metadata.bundleIdentifier,
                    declaredOriginalBundleIdentifier: metadata.originalBundleIdentifier,
                    existingOriginalBundleIdentifier: existing?.originalBundleIdentifier
                ),
                mappedBundleIdentifier: metadata.bundleIdentifier,
                name: metadata.name,
                version: metadata.version,
                buildNumber: metadata.buildNumber,
                size: size,
                iconRelativePath: files.iconRelativePath ?? existing?.iconRelativePath,
                state: .installed,
                expiryDate: metadata.expirationDate,
                accountID: resolvedAccountID,
                signingTeamID: metadata.signingTeamIdentifier ?? existing?.signingTeamID,
                // 关键：Seal 的证书序列号只能取运行包主程序的真实 CMS 签名者，
                // 绝不把描述文件授权证书列表当成实际签名者；身份读取失败时保留既有记录。
                // 爱思/其他工具签的 Seal，证书不是 Seal 创建的，旧记录里可能是 nil 或过期值，
                // 导致前置清理误撤 Seal 在用的证书 → 变砖（2026-09-15 真机确认）。
                certificateSerialNumber: metadata.installedIdentity?.mainTarget?.signerSerialNumber
                    ?? existing?.certificateSerialNumber,
                provisioningProfileExpirationDate: metadata.expirationDate,
                ipaRelativePath: files.ipaRelativePath,
                signedIPARelativePath: nil,
                preferredBundleIdentifier: metadata.bundleIdentifier,
                isSeal: true,
                isPinned: true,
                importedAt: existing?.importedAt ?? Date(),
                extensions: existing?.extensions ?? []
            )
            try await appStore.save(record)

        } catch {
            // 9. 失败回滚：取消暂存，旧文件不受影响
            try? await fileStore.cancel(staged)
            throw error
        }
    }

    // MARK: - 自替换启动对账：只确认/关闭事务，绝不发起安装

    /// 消费上一次启动留下的自替换事务。返回值表示是否发生了结算（记录被推进），
    /// 调用方在结算后必须重新读取记录，避免用旧快照覆盖刚确认的真实身份。
    @discardableResult
    private func reconcileSelfReplacement(
        existing: AppRecord?,
        accounts: [AppleAccountRecord],
        allRecords: [AppRecord]
    ) async throws -> Bool {
        guard let selfReplacement else { return false }
        switch try await selfReplacement.reconcileAtLaunch() {
        case .none, .awaitNextLaunch:
            return false
        case .closeAsNotInstalled:
            try await selfReplacement.closeAsNotInstalled()
            try? await logStore?.append(
                category: .installation,
                level: .warning,
                message: "自替换结算：仍在安装前身份，候选未落盘；事务已关闭，本轮不记为成功。",
                code: "SEAL-SELF-111"
            )
            return false
        case .requireRecovery(let reason):
            try await selfReplacement.requireRecovery(reason: reason)
            try? await logStore?.append(
                category: .installation,
                level: .error,
                message: "自替换结算：需要恢复（\(reason)）；已保留事务，不会把本轮记为成功。",
                code: "SEAL-SELF-112"
            )
            return false
        case .settle:
            let settled = try await selfReplacement.settle()
            if let main = settled.installedIdentity.mainTarget {
                let expiry = ISO8601DateFormatter().string(from: main.profileExpirationDate)
                try? await logStore?.append(
                    category: .installation,
                    message: "自替换结算确认：运行包身份与候选一致；Bundle=\(main.bundleIdentifier)，描述文件 \(main.profileUUID)，到期 \(expiry)，证书末尾 …\(main.signerSerialNumber.suffix(8))",
                    code: "SEAL-SELF-113"
                )
            }
            if let existing {
                try await atomicallyApplyInstalledIdentity(
                    settled.installedIdentity,
                    to: existing,
                    accounts: accounts
                )
            }
            // 先推进记录，再精准清理：清理发生时记录必须已指向候选身份，
            // 清理失败只进事务审计，不回滚已确认的安装身份。
            //
            // `protectedBundleIDs` 是这条路径**唯一**能保护其它 App 扩展的东西 ——
            // 它的保留集合只有 Seal 自己一个条目，别的 ID 全是候选，而扩展的设备端核验
            // 恒为「没装」⇒ 不保护就会被删。见 `ProfileCleanupRequest` 的说明。
            let request = ProfileCleanupRequest(
                transactionID: settled.transactionID,
                bundleIdentifier: settled.mainBundleIdentifier,
                keepingProfileUUID: settled.mainProfileUUID,
                installedIdentityReadAt: settled.installedIdentityReadAt,
                protectedBundleIDs: ProfileReclaimPolicy.protectedBundleIDs(records: allRecords)
            )
            let cleanup = await profileCleaner?.removeStaleProfiles(request)
                ?? ProfileCleanupSummary(stage: "skipped-no-cleaner")
            // 自替换结算清理是**唯一**会回收 Seal 自己那份堆积的路径 —— Seal 的自更新
            // 不走 `installSignedIPA`，所以「安装后旧描述文件清理」那条根本轮不到它。
            // 而它原先只把摘要写进事务审计、**不写日志**：真机上 Seal 堆了 16 份旧 profile，
            // 日志里却完全查不出这条清理到底跑没跑、是不是被判成了身份已变化。
            // 事务审计只在 App 内部可读，排障时拿到的只有日志 —— 所以必须同时落日志。
            try? await logStore?.append(
                category: .installation,
                message: "自替换结算清理：\(cleanup.logMessage)",
                code: "SEAL-PROFILE-322"
            )
            try await selfReplacement.finishCleanup(cleanup)
            return true
        }
    }

    /// 把结算确认的真实运行身份写入 Seal 记录：真实 signer 序列号、主 profile UUID、
    /// Team 与到期时间全部来自 `InstalledIdentity.mainTarget`，不读描述文件授权列表第一项。
    private func atomicallyApplyInstalledIdentity(
        _ identity: InstalledIdentity,
        to existing: AppRecord,
        accounts: [AppleAccountRecord]
    ) async throws {
        guard let main = identity.mainTarget else { return }
        var updated = existing
        updated.certificateSerialNumber = main.signerSerialNumber
        updated.provisioningProfileUUID = main.profileUUID
        updated.signingTeamID = main.teamIdentifier
        updated.expiryDate = main.profileExpirationDate
        updated.provisioningProfileExpirationDate = main.profileExpirationDate
        updated.signedArtifactStatus = .installed
        updated.accountID = SelfAppAccountBinding.resolvedAccountID(
            teamIdentifier: main.teamIdentifier,
            accounts: accounts,
            fallbackAccountID: existing.accountID
        )
        try await appStore.save(updated)
    }

    // MARK: - 清理重复的 Seal 记录

    private func cleanupDuplicateSealRecords(
        records: [AppRecord],
        keepID: UUID
    ) async throws {
        for record in records where record.isSeal && record.id != keepID {
            // 先删除文件，再删除数据库记录，避免产生孤儿文件
            try? await fileStore.removeApp(appID: record.id)
            try? await appStore.delete(id: record.id)
        }
    }

    /// 版本一致时的轻量回补：从**当前运行包**回补 Team/账号绑定与 profile 身份，不重打包 IPA。
    ///
    /// 为什么不能只看版本（R07）：同版本续签会换掉 profile（新 UUID、新有效期）但**版本号不变**。
    /// 旧实现在这个分支只回补 Team/账号就 `return`，于是数据库里的有效期始终停留在
    /// 「安装前乐观写入」的那一份 —— 一旦那次自更新实际失败（或进程在安装中被系统杀掉），
    /// UI 会显示一个设备上并不存在的有效期，用户直到应用被吊销都收不到提醒。
    ///
    /// **运行中的 Bundle 才是唯一可信证据**：它要么是新包（续签生效，读到新 profile），
    /// 要么是旧包（续签失败，读到旧 profile）。因此这里按 profile 身份结算，而不是按版本号。
    private func reconcileSealRecordFromRunningBundleIfNeeded(
        existing: AppRecord,
        metadata: SelfAppMetadata,
        accounts: [AppleAccountRecord]
    ) async throws {
        let resolvedTeamID = metadata.signingTeamIdentifier ?? existing.signingTeamID
        let resolvedAccountID = SelfAppAccountBinding.resolvedAccountID(
            teamIdentifier: resolvedTeamID,
            accounts: accounts,
            fallbackAccountID: existing.accountID
        )

        var updated = existing
        var changed = false

        if existing.signingTeamID != resolvedTeamID {
            updated.signingTeamID = resolvedTeamID
            changed = true
        }
        if existing.accountID != resolvedAccountID {
            updated.accountID = resolvedAccountID
            changed = true
        }

        // ── profile 身份：同版本续签唯一的可观测差异 ──
        if let uuid = metadata.provisioningProfileUUID,
           uuid != existing.provisioningProfileUUID {
            updated.provisioningProfileUUID = uuid
            changed = true
        }
        if let name = metadata.provisioningProfileName,
           name != existing.provisioningProfileName {
            updated.provisioningProfileName = name
            changed = true
        }
        if let creationDate = metadata.provisioningProfileCreationDate,
           creationDate != existing.provisioningProfileCreationDate {
            updated.provisioningProfileCreationDate = creationDate
            changed = true
        }
        if let expiry = metadata.expirationDate,
           expiry != existing.expiryDate || expiry != existing.provisioningProfileExpirationDate {
            // 结算：以运行包内的真实 profile 为准（可能是新包，也可能是回滚后的旧包）
            updated.expiryDate = expiry
            updated.provisioningProfileExpirationDate = expiry
            changed = true
        }

        // ── 证书序列号：同版本续签可能换证书，只能以运行包真实 CMS 签名者为准回补 ──
        // 描述文件授权证书列表不是实际签名者；身份读取失败时保留既有记录，
        // 避免前置清理误撤 Seal 在用的证书（2026-09-15 真机确认）。
        let resolvedCertSerial = metadata.installedIdentity?.mainTarget?.signerSerialNumber
            ?? existing.certificateSerialNumber
        if existing.certificateSerialNumber != resolvedCertSerial {
            updated.certificateSerialNumber = resolvedCertSerial
            changed = true
        }

        // 成品目标独立保留；旧包重启只能纠正安装快照，不能把待安装成品标成已安装。
        if existing.signedIPARelativePath != nil,
           let runningProfileUUID = metadata.provisioningProfileUUID,
           let target = existing.signingTargets.first(where: {
               $0.bundleIdentifier == metadata.bundleIdentifier
           }), let targetProfileUUID = target.profileUUID {
            let status: SignedArtifactStatus = targetProfileUUID.caseInsensitiveCompare(runningProfileUUID) == .orderedSame
                ? .installed : .awaitingVerification
            if existing.signedArtifactStatus != status {
                updated.signedArtifactStatus = status
                changed = true
            }
        }

        // version / buildNumber **不在这里对齐**：它们是 AppRecord 的 `let` 常量。
        // 版本变化时走的是 `atomicallyUpdateSealRecord`（用运行包重打包并整体重建记录），
        // 本函数只在「版本一致」分支被调用，因此不存在「DB 版本 ≠ 运行版本」的窗口。

        guard changed else { return }
        try await appStore.save(updated)
    }
}
