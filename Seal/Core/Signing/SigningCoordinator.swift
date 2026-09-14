import Foundation
import UIKit
import ZIPFoundation
@preconcurrency import AltSign

/// 「撤销并继续签名」（SEAL-CERT-204e 确认）的执行结果。
struct KeylessCertificateSacrificeResult: Sendable {
    /// 实际撤销成功的证书序列号（原始格式，仅用于日志/比对）。
    let revokedSerials: [String]
    /// 因撤销而失效、需要重新签名安装的已装 App。
    let affectedInstalledApps: [AppRecord]
}

actor SigningCoordinator {
    private let appStore: any AppStore
    private let accountRepository: any AccountRepository
    private let keychain: KeychainVault
    private let fileStore: AppFileStore
    private let installChannel: any InstallChannel
    private let portal: ApplePortalSigningService
    private let logStore: SealLogStore?

    init(
        appStore: any AppStore,
        accountRepository: any AccountRepository,
        keychain: KeychainVault,
        fileStore: AppFileStore,
        installChannel: any InstallChannel,
        portal: ApplePortalSigningService = ApplePortalSigningService(),
        logStore: SealLogStore? = nil
    ) {
        self.appStore = appStore
        self.accountRepository = accountRepository
        self.keychain = keychain
        self.fileStore = fileStore
        self.installChannel = installChannel
        self.portal = portal
        self.logStore = logStore
    }

    func signAndInstall(
        appID: UUID,
        accountID: UUID,
        requestedBundleIdentifier: String? = nil,
        selectedCertificateSerialNumber: String? = nil,
        allowDroppingExtensions: Bool = true,
        installAfterSigning: Bool = true,
        forceResign: Bool = false,
        bypassFreeAccountDeviceLimit: Bool = false,
        progress: @Sendable (SigningStage) async -> Void,
        // 证书序列号一旦确定（复用缓存或新申请）即回传，供 UI 显示真实证书，
        // 避免只持有“签名开始时快照”而在失败回看时误显示“证书未准备”。
        onCertificateResolved: @Sendable @escaping (String) async -> Void = { _ in },
        // 安装阶段 IPC 传输进度（0-1），透传到 InstallChannel 的上传回调。
        onInstallProgress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> AppRecord {
        guard var app = try await appStore.fetchAll().first(where: { $0.id == appID }) else {
            throw Self.failure(
                reason: "未找到要签名的应用记录（应用 ID：\(appID)）。",
                recovery: "重新导入 IPA",
                code: "SEAL-SIGN-404"
            )
        }
        guard var account = try await accountRepository.fetchAll().first(where: {
            $0.id == accountID
        }) else {
            throw Self.failure(
                reason: "签名账号记录不存在",
                recovery: "添加 Apple ID",
                code: "SEAL-AUTH-105"
            )
        }
        guard var secret = try await keychain.load(accountID: accountID) else {
            account.status = .needsVerification
            account.verificationFailureReason = .localCredentialsMissing
            try? await accountRepository.save(account)
            throw Self.failure(
                reason: "本机 Keychain 中缺少当前 Apple ID 的登录凭据。",
                recovery: "重新验证 Apple ID",
                code: "SEAL-AUTH-105a"
            )
        }
        try await validateAccountSession(
            account: account,
            secret: secret,
            selectedAccountID: accountID
        )
        let normalizedSigningMaterial = try await normalizeCachedCertificateState(
            account: account,
            secret: secret
        )
        account = normalizedSigningMaterial.account
        secret = normalizedSigningMaterial.secret
        try SigningCertificateSelectionPolicy.validateAccountAndTeam(
            for: app,
            account: account
        )
        let effectiveCertificateSerialNumber = try SigningCertificateSelectionPolicy
            .resolvedSerialNumber(
                for: app,
                account: account,
                requestedSerialNumber: selectedCertificateSerialNumber
            )
        // 尽早回传实际使用的证书序列号（覆盖复用缓存证书、直接走已签包的路径）。
        if let resolvedCertificateSerialNumber = effectiveCertificateSerialNumber {
            await onCertificateResolved(resolvedCertificateSerialNumber)
        }
        let targetBundleIdentifier = try BundleIDPolicy.targetBundleIdentifier(
            for: app,
            requestedBundleIdentifier: requestedBundleIdentifier
        )
        let workspaceRoot = try await fileStore.signingWorkspace(appID: appID)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }
        let originalState = app.state
        let originalSecret = secret
        let originalAccount = account
        var didPersistNewSignedArtifact = false

        do {
            try Task.checkCancellation()
            // 免费账号每台设备最多同时 3 个自签应用（含 Seal 自身）；installd 超限只报模糊
            // 错误并长时间转圈，这里按本机记录提前拦截给出明确指引。
            try await enforceFreeAccountInstallLimit(
                app: app,
                account: account,
                bypassFreeAccountDeviceLimit: bypassFreeAccountDeviceLimit
            )
            // 导入与已安装 IPA 相同（签名后 Bundle ID 一致）时，提前拦截，避免生成
            // 拥有相同 Bundle ID 的重复记录与重复文件夹。
            try await enforceBundleIdentifierUniqueness(
                app: app,
                targetBundleIdentifier: targetBundleIdentifier
            )
            let deviceIdentifier: String
            // 宽松策略：通道暂时不可用时不中止签名，先用配对缓存的 UDID 完成签名，
            // 签名完成后再尝试启动通道安装（签名耗时通常足够 VPN/Minimuxer 恢复）
            var channelReady = false
            if installAfterSigning {
                try await updateState(appID: appID, stage: .waitingForChannel)
                await progress(.waitingForChannel)
                do {
                    deviceIdentifier = try await installChannel.start()
                    channelReady = true
                } catch {
                    if let cached = await installChannel.storedDeviceIdentifier(),
                       cached.isEmpty == false {
                        deviceIdentifier = cached
                    } else {
                        throw Self.failure(
                            reason: "签名前需要先完成一次设备配对，以便按 Apple 官方设备列表生成描述文件。",
                            recovery: "先完成设备配对后重试",
                            code: "SEAL-PAIR-211"
                        )
                    }
                }
            } else if let storedDeviceIdentifier = await installChannel.storedDeviceIdentifier(),
                      storedDeviceIdentifier.isEmpty == false {
                deviceIdentifier = storedDeviceIdentifier
            } else {
                throw Self.failure(
                    reason: "签名前需要先完成一次设备配对，以便按 Apple 官方设备列表生成描述文件。",
                    recovery: "先完成设备配对后重试",
                    code: "SEAL-PAIR-211"
                )
            }

            if installAfterSigning, !forceResign,
               let cachedInstall = try await installCachedSignedIPAIfPossible(
                app: app,
                account: account,
                targetBundleIdentifier: targetBundleIdentifier,
                certificateSerialNumber: effectiveCertificateSerialNumber,
                deviceIdentifier: deviceIdentifier,
                progress: progress,
                onInstallProgress: onInstallProgress
            ) {
                return cachedInstall
            }

            let originalURL = try await fileStore.fileURL(
                relativePath: app.ipaRelativePath
            )
            let preferredIconData: Data?
            if let preferredIconPath = app.preferredIconRelativePath {
                preferredIconData = try? await fileStore.read(relativePath: preferredIconPath)
            } else {
                preferredIconData = nil
            }
            let portalResult: PortalSigningResult
            do {
                portalResult = try await portal.sign(
                    app: app,
                    account: account,
                    secret: secret,
                    deviceIdentifier: deviceIdentifier,
                    originalIPAURL: originalURL,
                    workspaceRoot: workspaceRoot,
                    targetBundleIdentifier: targetBundleIdentifier,
                    preferredIconData: preferredIconData,
                    selectedCertificateSerialNumber: effectiveCertificateSerialNumber,
                    allowDroppingExtensions: allowDroppingExtensions,
                    persistSigningMaterial: { updatedSecret, serialNumber in
                        try await self.persistNewSigningMaterial(
                            updatedSecret,
                            serialNumber: serialNumber,
                            accountID: accountID,
                            originalSecret: originalSecret,
                            originalAccount: originalAccount
                        )
                    },
                    progress: { stage in
                        await progress(stage)
                    }
                )
            } catch let failure as ImportFailure where Self.isOrphanCertificateBlocking(failure) {
                // 覆盖安装后 keychain 清空：远端仍存在的证书对本机永远不可用
                // （Apple 只存公钥、私钥已随旧 keychain 不可读）。唯一的无感出路是
                // 撤掉「无人使用的孤儿证书」腾出名额后新建。撤销不可逆，仅在四重核验
                // 全部通过时自动执行（无私钥 ∧ 无已装 App ∧ 设备端 profile 未引用 ∧
                // 核验成功）；仍在被已装 App 使用的无钥匙证书不静默撤，抛 204e 交给
                // 失败页「撤销并继续签名」一键确认流程。
                let cleanupOutcome = try await autoCleanOrphanCertificatesIfPossible(
                    account: account,
                    secret: secret
                )
                guard cleanupOutcome == .cleaned,
                      let refreshedSecret = try await keychain.load(accountID: accountID) else {
                    if case .blockedByInUseKeylessCerts(let appNames, let deviceOnlyCount) = cleanupOutcome {
                        throw Self.inUseKeylessCertificatesFailure(
                            appNames: appNames,
                            deviceOnlyCount: deviceOnlyCount
                        )
                    }
                    throw failure
                }
                // 原绑定已随清理撤销，重试必须不带选中序列号，走「复用剩余证书或新建」。
                let cleanupRetryWorkspaceRoot = workspaceRoot.appending(
                    path: "OrphanCleanupRetry-\(UUID().uuidString)"
                )
                portalResult = try await portal.sign(
                    app: app,
                    account: account,
                    secret: refreshedSecret,
                    deviceIdentifier: deviceIdentifier,
                    originalIPAURL: originalURL,
                    workspaceRoot: cleanupRetryWorkspaceRoot,
                    targetBundleIdentifier: targetBundleIdentifier,
                    preferredIconData: preferredIconData,
                    selectedCertificateSerialNumber: nil,
                    allowDroppingExtensions: allowDroppingExtensions,
                    persistSigningMaterial: { updatedSecret, serialNumber in
                        try await self.persistNewSigningMaterial(
                            updatedSecret,
                            serialNumber: serialNumber,
                            accountID: accountID,
                            originalSecret: originalSecret,
                            originalAccount: originalAccount
                        )
                    },
                    progress: { stage in
                        await progress(stage)
                    }
                )
            }

            account.certificateSerialNumber = portalResult.certificateSerialNumber
            account.selectedCertificateSerialNumber = portalResult.certificateSerialNumber
            account.status = .verified
            account.verificationFailureReason = nil
            account.lastVerifiedAt = Date()
            try await accountRepository.save(account)
            // 新申请证书路径：portal 返回后序列号才最终确定，再回传一次（幂等）。
            await onCertificateResolved(portalResult.certificateSerialNumber)

            let signedPath = try await fileStore.storeSignedIPA(
                sourceURL: portalResult.signedIPAURL,
                appID: appID
            )
            let signedSHA256 = try await fileStore.sha256(relativePath: signedPath)
            // Seal 自身例外：自更新安装会替换本进程，这是安装前唯一的写入机会；
            // 而且它的顶层快照由启动同步从**运行中的 Bundle** 结算（R07/D 包），
            // 装失败时这份乐观值会被推翻，不会留下假日期。
            applySigningResult(
                portalResult,
                signedPath: signedPath,
                accountID: accountID,
                advancesInstalledSnapshot: originalState != .installed || app.isSeal,
                to: &app
            )
            app.signedIPASHA256 = signedSHA256
            app.signedArtifactStatus = SignedArtifactSnapshot.statusAfterSigning(
                originalState: originalState,
                isSeal: app.isSeal
            )
            app.lastInstallFailureCode = nil
            app.lastInstallFailureReason = nil
            app.state = originalState == .installed ? .installed : .signed
            try await appStore.save(app)
            didPersistNewSignedArtifact = true

            guard installAfterSigning else { return app }

            // 签名时通道若未就绪，安装前再试一次启动（签名期间通道可能已恢复）
            if channelReady == false {
                _ = try? await installChannel.start()
            }

            let installed = try await installSignedIPA(
                app: app,
                signedPath: signedPath,
                bundleIdentifier: portalResult.mappedMainBundleID,
                expirationDate: portalResult.expirationDate,
                progress: progress,
                onInstallProgress: onInstallProgress
            )
            return installed
        } catch is CancellationError {
            if app.signedIPARelativePath != nil, originalState != .installed {
                app.state = .signed
            } else {
                app.state = originalState
            }
            try await persistAppState(app)
            throw CancellationError()
        } catch let failure as ImportFailure {
            // 只有明确凭据/本地凭据问题才写入 needsVerification；网络、限流、107 会话过期不写。
            if let verificationReason = AppleServiceFailurePolicy.verificationFailureReason(for: failure) {
                account.status = .needsVerification
                account.verificationFailureReason = verificationReason
                try? await accountRepository.save(account)
            }
            if didPersistNewSignedArtifact || failure.code.hasPrefix("SEAL-INSTALL-") {
                app.state = originalState == .installed ? .installed : .signed
                app.signedArtifactStatus = .installFailed
                app.lastInstallFailureCode = failure.code
                app.lastInstallFailureReason = failure.reason
            } else {
                app.state = originalState == .installed ? .installed : originalState
            }
            try await persistAppState(app)
            throw failure
        } catch {
            if didPersistNewSignedArtifact {
                app.state = originalState == .installed ? .installed : .signed
                app.signedArtifactStatus = .installFailed
                app.lastInstallFailureCode = "SEAL-INSTALL-500"
                app.lastInstallFailureReason = "安装流程遇到未预期错误，技术信息已写入脱敏日志。"
            } else {
                app.state = originalState == .installed ? .installed : originalState
            }
            try await persistAppState(app)
            throw error
        }
    }


    /// 只有「本机无私钥/绑定失效/证书名额满」这几类阻断才可能由孤儿证书清理盘活。
    /// 名额满有两条平行归类路径，必须全部覆盖：204a（按 Apple 错误文案归类）
    /// 与 204b（`createSigningIdentity` 按 isCertificateLimitError 归类）——
    /// 2026-09-14 真机踩到：只挂 204a 时 204b 直接抛给用户，无感清理完全不触发。
    /// 非 static 以便测试直接构造 actor 调用之外的纯判定 → 保持 static 供单测断言。
    static func isOrphanCertificateBlocking(_ failure: ImportFailure) -> Bool {
        failure.code == "SEAL-CERT-204a"
            || failure.code == "SEAL-CERT-204b"
            || failure.code == "SEAL-CERT-204c"
            || failure.code == "SEAL-CERT-204d"
    }

    private enum OrphanCleanupOutcome: Equatable {
        /// 撤掉 ≥1 张孤儿证书，名额已释放，可重试签名。
        case cleaned
        /// 设备端核验或远端清单不可用：无法精准判定，回退原始错误手动处理。
        case unavailable
        /// 没有可安全撤销的孤儿证书，但存在「本机无私钥且仍在被已装 App 使用」的
        /// 证书占位 —— 静默撤会让这些 App 立即失效，必须升级为用户确认（SEAL-CERT-204e）。
        case blockedByInUseKeylessCerts(appNames: [String], deviceOnlyCount: Int)
        /// 连无钥匙证书都没有（与触发条件矛盾，防御分支）。
        case noCandidates
        /// 有候选但全部撤销失败，名额未释放。
        case revokeFailed
    }

    /// 仍可被一键确认盘活（SEAL-CERT-204e）：账号下存在「本机无私钥」的证书，
    /// 但它们仍被本机已安装应用使用，静默撤销会让这些应用立即打不开。
    private static func inUseKeylessCertificatesFailure(
        appNames: [String],
        deviceOnlyCount: Int
    ) -> ImportFailure {
        let affected: String
        if appNames.isEmpty {
            affected = "这些证书仍被本机 \(deviceOnlyCount) 个其他来源的应用使用"
        } else {
            let extra = deviceOnlyCount > 0 ? "，另有 \(deviceOnlyCount) 个其他来源的应用" : ""
            affected = "仍在使用旧证书的应用：\(appNames.joined(separator: "、"))\(extra)"
        }
        return ImportFailure(
            title: "证书名额被占用",
            reason: "Apple 账号下的旧证书因覆盖安装已丢失本机私钥，无法继续用于签名；但仍有应用靠它们运行。\(affected)。",
            recovery: "点「撤销并继续签名」将自动撤销旧证书（对应应用立即失效、需重新签名安装）、申请新证书并完成本次签名；受影响的已装应用会自动重签。证书状态可随时在「我的」→「签名证书」查看",
            code: "SEAL-CERT-204e"
        )
    }

    /// 绑定还在但本机已没有对应私钥 → 该绑定永远不可用（signingIdentity 会校验 P12），
    /// 清掉让后续签名走「无绑定 → 复用剩余证书或新建」，避免反复撞 204c/204d。
    private func clearUnusableCertificateBinding(
        account: AppleAccountRecord,
        secret: AccountSecret
    ) async {
        guard let bound = secret.certificateSerialNumber,
              bound.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              secret.p12(for: bound) == nil else { return }
        var clearedSecret = secret
        clearedSecret.certificateP12 = nil
        clearedSecret.certificateSerialNumber = nil
        clearedSecret.certificateMachineIdentifier = nil
        try? await keychain.save(clearedSecret, for: account.id)
        var clearedAccount = account
        clearedAccount.certificateSerialNumber = nil
        clearedAccount.selectedCertificateSerialNumber = nil
        try? await accountRepository.save(clearedAccount)
    }

    /// 签名失败页「撤销并继续签名」（SEAL-CERT-204e）确认后调用：撤销账号下**所有**
    /// 本机无私钥的远端证书（含仍被已装 App 使用的），返回因撤销而失效、需要重新
    /// 签名的已装 App。
    /// 调用前必须已取得用户明确确认 —— 撤销会让仍在用这些证书的 App 立即打不开。
    func revokeKeylessCertificatesAfterConfirmation(
        accountID: UUID
    ) async throws -> KeylessCertificateSacrificeResult {
        guard let account = try await accountRepository.fetchAll().first(where: {
            $0.id == accountID
        }) else {
            throw Self.failure(
                reason: "签名账号记录不存在",
                recovery: "添加 Apple ID",
                code: "SEAL-AUTH-105"
            )
        }
        guard let secret = try await keychain.load(accountID: accountID) else {
            throw Self.failure(
                reason: "本机 Keychain 中缺少当前 Apple ID 的登录凭据。",
                recovery: "重新验证 Apple ID",
                code: "SEAL-AUTH-105a"
            )
        }
        let inventoryService = ApplePortalInventoryService()
        let inventory = try await inventoryService.fetchInventory(
            account: account,
            secret: secret,
            scope: .certificates
        )
        // 与签名链路 secret.p12(for:) 同口径：current + 历史 map 里全部可用 P12。
        var localUsableSerials = Set<String>()
        for certificate in inventory.certificates {
            guard let data = secret.p12(for: certificate.serialNumber),
                  let local = try? ALTCertificate(p12Data: data, password: nil),
                  SigningCertificateSelectionPolicy.normalizedSerialNumber(local.serialNumber)
                      == SigningCertificateSelectionPolicy.normalizedSerialNumber(certificate.serialNumber)
            else { continue }
            localUsableSerials.insert(
                SigningCertificateSelectionPolicy.normalizedSerialNumber(certificate.serialNumber)
            )
        }
        let candidates = CertificateCleanupPolicy.sacrificeCandidates(
            certificates: inventory.certificates,
            localUsableSerials: localUsableSerials
        )
        guard candidates.isEmpty == false else {
            return KeylessCertificateSacrificeResult(revokedSerials: [], affectedInstalledApps: [])
        }
        let certificateService = ApplePortalCertificateService()
        var revokedSerials: [String] = []
        for certificate in candidates {
            if (try? await certificateService.revokeCertificate(
                serialNumber: certificate.serialNumber,
                account: account,
                secret: secret
            )) != nil {
                revokedSerials.append(certificate.serialNumber)
            }
        }
        guard revokedSerials.isEmpty == false else {
            throw Self.failure(
                reason: "撤销 \(candidates.count) 张无钥匙证书全部失败，证书名额未释放。",
                recovery: "稍后重试；仍失败请到「我的」→「签名证书」检查账号状态",
                code: "SEAL-CERT-204f"
            )
        }
        await clearUnusableCertificateBinding(account: account, secret: secret)

        let revokedNormalized = Set(revokedSerials.map {
            SigningCertificateSelectionPolicy.normalizedSerialNumber($0)
        })
        let apps = (try? await appStore.fetchAll()) ?? []
        let affectedInstalledApps = apps.filter { app in
            guard app.belongsInInstalledList,
                  let serial = app.certificateSerialNumber else { return false }
            return revokedNormalized.contains(
                SigningCertificateSelectionPolicy.normalizedSerialNumber(serial)
            )
        }
        try? await logStore?.append(
            category: .signing,
            message: "用户确认后撤销 \(revokedSerials.count) 张无钥匙证书；受影响待重签应用 \(affectedInstalledApps.count) 个"
        )
        return KeylessCertificateSacrificeResult(
            revokedSerials: revokedSerials,
            affectedInstalledApps: affectedInstalledApps
        )
    }

    /// 自动盘活：精准撤销「四重条件全过」的孤儿证书，释放名额后由调用方清绑定重试。
    ///
    /// 无感的前提（任一不满足即返回 false，原错误照常提示用户手动处理）：
    /// - 设备端核验必须成功：签名场景设备已连接，misagent dump 可用；dump 失败 =
    ///   无法确认「没有其他工具装的 App 在用这张证书」，绝不盲撤；
    /// - 远端清单必须拉到：判定基于当下 Apple 侧状态，不用缓存；
    /// - 至少成功撤销一张（名额没有释放时重试无意义）。
    ///
    /// 残留风险（用户已知情决策，2026-09-14）：同一 Apple ID 在**其他设备**上安装的
    /// App 不在本机描述文件里，其证书可能被一并撤销。
    private func autoCleanOrphanCertificatesIfPossible(
        account: AppleAccountRecord,
        secret: AccountSecret
    ) async throws -> OrphanCleanupOutcome {
        guard let deviceReferenced = await DeviceProfileInspector.referencedCertificateSerials() else {
            try? await logStore?.append(
                category: .signing,
                message: "证书自动清理跳过：设备端描述文件核验不可用，回退手动处理"
            )
            return .unavailable
        }
        let inventoryService = ApplePortalInventoryService()
        guard let inventory = try? await inventoryService.fetchInventory(
            account: account,
            secret: secret,
            scope: .certificates
        ) else {
            try? await logStore?.append(
                category: .signing,
                message: "证书自动清理跳过：无法获取 Apple 最新证书清单"
            )
            return .unavailable
        }

        // 与签名链路 secret.p12(for:) 同口径：current + 历史 map 里全部可用 P12。
        var localUsableSerials = Set<String>()
        for certificate in inventory.certificates {
            guard let data = secret.p12(for: certificate.serialNumber),
                  let local = try? ALTCertificate(p12Data: data, password: nil),
                  SigningCertificateSelectionPolicy.normalizedSerialNumber(local.serialNumber)
                      == SigningCertificateSelectionPolicy.normalizedSerialNumber(certificate.serialNumber)
            else { continue }
            localUsableSerials.insert(
                SigningCertificateSelectionPolicy.normalizedSerialNumber(certificate.serialNumber)
            )
        }

        let apps = (try? await appStore.fetchAll()) ?? []
        let plan = CertificateCleanupPolicy.makePlan(
            certificates: inventory.certificates,
            apps: apps,
            localUsableSerials: localUsableSerials,
            deviceReferencedSerials: deviceReferenced
        )
        guard plan.revocable.isEmpty == false else {
            // 无孤儿可撤：区分「全部无钥匙证书都在用」（可一键确认盘活）与其他情况。
            let keyless = CertificateCleanupPolicy.sacrificeCandidates(
                certificates: inventory.certificates,
                localUsableSerials: localUsableSerials
            )
            guard keyless.isEmpty == false else {
                try? await logStore?.append(
                    category: .signing,
                    message: "证书自动清理跳过：\(inventory.certificates.count) 张远端证书本机均有私钥或不存在占位问题"
                )
                return .noCandidates
            }
            var affectedNames: [String] = []
            var seenAppIDs = Set<UUID>()
            for certificate in keyless {
                for affected in CertificateRevocationImpact.affectedApps(
                    serialNumber: certificate.serialNumber,
                    apps: apps
                ) where seenAppIDs.insert(affected.id).inserted {
                    affectedNames.append(affected.name)
                }
            }
            let sealAssociatedSerials = Set(apps.compactMap(\.certificateSerialNumber).map {
                SigningCertificateSelectionPolicy.normalizedSerialNumber($0)
            })
            let deviceOnlyCount = keyless.filter {
                let serial = SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber)
                return deviceReferenced.contains(serial) && sealAssociatedSerials.contains(serial) == false
            }.count
            try? await logStore?.append(
                category: .signing,
                level: .warning,
                message: "证书自动清理需要用户确认：\(keyless.count) 张无钥匙证书仍被应用使用（Seal 记录 \(affectedNames.count) 个，设备端其他来源 \(deviceOnlyCount) 个）"
            )
            return .blockedByInUseKeylessCerts(
                appNames: affectedNames,
                deviceOnlyCount: deviceOnlyCount
            )
        }

        let certificateService = ApplePortalCertificateService()
        var revokedSerials: [String] = []
        for certificate in plan.revocable {
            if (try? await certificateService.revokeCertificate(
                serialNumber: certificate.serialNumber,
                account: account,
                secret: secret
            )) != nil {
                revokedSerials.append(certificate.serialNumber)
            }
        }
        guard revokedSerials.isEmpty == false else {
            try? await logStore?.append(
                category: .signing,
                level: .error,
                message: "证书自动清理失败：\(plan.revocable.count) 张候选全部撤销失败"
            )
            return .revokeFailed
        }

        // 绑定还在但本机已无私钥 → 永远不可用，清掉让重试走「无绑定 → 复用剩余或新建」。
        await clearUnusableCertificateBinding(account: account, secret: secret)

        try? await logStore?.append(
            category: .signing,
            message: "证书自动清理完成：撤销 \(revokedSerials.count)/\(plan.revocable.count) 张无人使用的孤儿证书（末尾 \(revokedSerials.map { "…" + SigningCertificateSelectionPolicy.normalizedSerialNumber($0).suffix(6) }.joined(separator: "、"))），正在重试签名"
        )
        return .cleaned
    }

    func installSignedArtifact(
        appID: UUID,
        progress: @Sendable (SigningStage) async -> Void
    ) async throws -> AppRecord {
        guard var app = try await appStore.fetchAll().first(where: { $0.id == appID }),
              let signedPath = app.signedIPARelativePath,
              let expectedSHA256 = app.signedIPASHA256,
              let bundleIdentifier = app.mappedBundleIdentifier,
              let expirationDate = app.provisioningProfileExpirationDate else {
            throw Self.failure(
                reason: "本机签名包记录不完整。",
                recovery: "重新签名",
                code: "SEAL-INSTALL-719"
            )
        }
        guard try await fileStore.exists(relativePath: signedPath) else {
            app.signedArtifactStatus = .missing
            try await persistAppState(app)
            throw Self.failure(
                reason: "本机保存的签名包文件缺失。",
                recovery: "重新签名",
                code: "SEAL-INSTALL-711"
            )
        }
        guard try await fileStore.validateSHA256(relativePath: signedPath, expected: expectedSHA256) else {
            app.signedArtifactStatus = .damaged
            try await persistAppState(app)
            throw Self.failure(
                reason: "本机签名包的 SHA-256 校验不一致。",
                recovery: "重新签名",
                code: "SEAL-INSTALL-712"
            )
        }
        guard expirationDate > Date() else {
            app.signedArtifactStatus = .expired
            try await persistAppState(app)
            throw Self.failure(
                reason: "本机签名包的描述文件已经过期。",
                recovery: "重新签名",
                code: "SEAL-INSTALL-713"
            )
        }
        guard BundleIDPolicy.validationError(for: bundleIdentifier) == nil else {
            app.signedArtifactStatus = .damaged
            try await persistAppState(app)
            throw Self.failure(
                reason: "本机签名包的 Bundle ID 记录不完整或格式无效。",
                recovery: "重新签名",
                code: "SEAL-INSTALL-716"
            )
        }

        await progress(.waitingForChannel)
        let currentDeviceIdentifier = try await installChannel.start()
        // 三入口共用校验：**逐个 target** 核对（主程序 + 每个扩展）。
        // 此前这里只查主 target，于是「主 profile 有效、扩展 profile 已过期」的包
        // 能一路走到设备端，失败信息还是设备端的模糊错误。
        if case let .rejected(failure) = PreInstallValidation.validate(
            app: app,
            bundleIdentifier: bundleIdentifier,
            deviceIdentifier: currentDeviceIdentifier,
            accountTeamID: app.signingTeamID,
            certificateSerialNumber: app.certificateSerialNumber
        ) {
            app.signedArtifactStatus = PreInstallValidation.artifactStatus(forCode: failure.code)
            try await persistAppState(app)
            throw failure
        }

        do {
            return try await installSignedIPA(
                app: app,
                signedPath: signedPath,
                bundleIdentifier: bundleIdentifier,
                expirationDate: expirationDate,
                progress: progress
            )
        } catch let failure as ImportFailure {
            app.state = app.state == .installed ? .installed : .signed
            app.signedArtifactStatus = .installFailed
            app.lastInstallFailureCode = failure.code
            app.lastInstallFailureReason = failure.reason
            try await persistAppState(app)
            throw failure
        } catch {
            app.state = app.state == .installed ? .installed : .signed
            app.signedArtifactStatus = .installFailed
            app.lastInstallFailureCode = "SEAL-INSTALL-500"
            app.lastInstallFailureReason = "安装流程遇到未预期错误，技术信息已写入脱敏日志。"
            try await persistAppState(app)
            throw error
        }
    }

    private func persistNewSigningMaterial(
        _ updatedSecret: AccountSecret,
        serialNumber: String,
        accountID: UUID,
        originalSecret: AccountSecret,
        originalAccount: AppleAccountRecord
    ) async throws {
        do {
            try await keychain.save(updatedSecret, for: accountID)
            guard let reloaded = try await keychain.load(accountID: accountID),
                  reloaded.certificateSerialNumber?.caseInsensitiveCompare(serialNumber) == .orderedSame,
                  let p12 = reloaded.certificateP12,
                  let certificate = try? ALTCertificate(p12Data: p12, password: nil),
                  certificate.serialNumber.caseInsensitiveCompare(serialNumber) == .orderedSame else {
                throw Self.failure(
                    reason: "签名证书已从 Apple 获取，但写入本机 Keychain 后未能通过校验（重载的证书序列号与预期不一致）。",
                    recovery: "重试；如持续失败请到「我的」→「签名证书」中撤销旧证书后重试",
                    code: "SEAL-CERT-210"
                )
            }

            var updatedAccount = originalAccount
            updatedAccount.certificateSerialNumber = serialNumber
            updatedAccount.selectedCertificateSerialNumber = serialNumber
            updatedAccount.status = .verified
            updatedAccount.verificationFailureReason = nil
            updatedAccount.lastVerifiedAt = Date()
            try await accountRepository.save(updatedAccount)
        } catch {
            let originalError = error
            var rollbackFailures: [String] = []
            do {
                try await keychain.save(originalSecret, for: accountID)
            } catch {
                rollbackFailures.append("Keychain")
            }
            do {
                try await accountRepository.save(originalAccount)
            } catch {
                rollbackFailures.append("账号记录")
            }
            if rollbackFailures.isEmpty == false {
                throw Self.failure(
                    reason: "证书保存失败，且本地补偿未完整完成（\(rollbackFailures.joined(separator: "、"))）。",
                    recovery: "重新验证 Apple ID 后检查证书状态",
                    code: "SEAL-CERT-215"
                )
            }
            throw originalError
        }
    }

    /// 把签名产物的信息落进记录。
    ///
    /// `advancesInstalledSnapshot` 决定**是否推进顶层 profile 字段**
    /// （`provisioningProfile*` 四个）。这些顶层字段描述的是「设备上正在运行的那份构建」，
    /// UI 展示的到期日取的是 `provisioningProfileExpirationDate ?? expiryDate`。
    /// 已安装的第三方应用重签时若提前推进，一旦安装失败或进程中途被杀，
    /// 界面就会显示一个设备上并不存在的到期日（R08：新旧日期混用），
    /// 用户以为续签成功，直到应用被吊销才发现问题。
    /// 产物身份由 `signingTargets` 承载，顶层快照等安装校验通过后再由
    /// `advanceInstalledSnapshot(of:bundleIdentifier:expiryDate:)` 推进。
    private func applySigningResult(
        _ result: PortalSigningResult,
        signedPath: String,
        accountID: UUID,
        advancesInstalledSnapshot: Bool,
        to app: inout AppRecord
    ) {
        let mainBinding = result.profileBindings[result.mappedMainBundleID]
        app.mappedBundleIdentifier = result.mappedMainBundleID
        app.preferredBundleIdentifier = result.mappedMainBundleID
        app.accountID = accountID
        app.signingTeamID = result.teamID
        app.certificateSerialNumber = result.certificateSerialNumber
        app.signedDeviceIdentifier = result.deviceIdentifier
        app.signedIPARelativePath = signedPath
        if advancesInstalledSnapshot {
            app.provisioningProfileUUID = mainBinding?.profileUUID
            app.provisioningProfileName = mainBinding?.profileName
            app.provisioningProfileCreationDate = mainBinding?.creationDate
            app.provisioningProfileExpirationDate = mainBinding?.expirationDate
        }
        app.entitlementValidationStatus = "已按 embedded.mobileprovision 校验"
        app.capabilityValidationStatus = "已按 Apple App ID 与描述文件校验"
        app.lastSignedAt = Date()
        app.removedExtensionBundleIdentifiers = result.droppedExtensionBundleIdentifiers
        app.signingTargets = result.profileBindings.values
            .map(SigningTargetRecord.init(binding:))
            .sorted { $0.bundleIdentifier < $1.bundleIdentifier }

        app.extensions.removeAll {
            result.droppedExtensionBundleIdentifiers.contains(
                $0.originalBundleIdentifier
            )
        }
        for index in app.extensions.indices {
            let mapped = result.mappedBundleIdentifiers[
                app.extensions[index].originalBundleIdentifier
            ]
            app.extensions[index].mappedBundleIdentifier = mapped
            if let mapped, let binding = result.profileBindings[mapped] {
                app.extensions[index].provisioningProfileUUID = binding.profileUUID
                app.extensions[index].provisioningProfileName = binding.profileName
                app.extensions[index].provisioningProfileExpirationDate = binding.expirationDate
                app.extensions[index].certificateSerialNumber = result.certificateSerialNumber
            }
        }
    }

    private func installCachedSignedIPAIfPossible(
        app: AppRecord,
        account: AppleAccountRecord,
        targetBundleIdentifier: String,
        certificateSerialNumber: String?,
        deviceIdentifier: String,
        progress: @Sendable (SigningStage) async -> Void,
        onInstallProgress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> AppRecord? {
        guard let signedPath = app.signedIPARelativePath,
              let expectedSHA256 = app.signedIPASHA256,
              let mappedBundleIdentifier = app.mappedBundleIdentifier,
              mappedBundleIdentifier.caseInsensitiveCompare(targetBundleIdentifier) == .orderedSame,
              app.accountID == account.id,
              app.signingTeamID?.caseInsensitiveCompare(account.teamID) == .orderedSame,
              let storedSerial = app.certificateSerialNumber,
              let certificateSerialNumber,
              // 序列号跨来源比对必须归一化（去前导零）：直接字符串比对会把同一张证书
              // 判成「已被轮换」，于是缓存永远命中不了、每次都白重签一遍。
              SigningCertificateSelectionPolicy.normalizedSerialNumber(storedSerial)
                == SigningCertificateSelectionPolicy.normalizedSerialNumber(certificateSerialNumber),
              app.signedDeviceIdentifier?.caseInsensitiveCompare(deviceIdentifier) == .orderedSame,
              let pendingExpiration = app.provisioningProfileExpirationDate,
              pendingExpiration > Date(),
              app.state != .installed || app.expiryDate != pendingExpiration else {
            return nil
        }

        // 缓存复用路径此前**完全不查 target 明细**：主 profile 有效、扩展 profile 已过期的包
        // 会被直接复用并装到设备上。这里补上与其他两条入口相同的校验；
        // 不通过就返回 nil，让调用方回落到重新签名（而不是把坏包装到设备上）。
        if case .rejected = PreInstallValidation.validate(
            app: app,
            bundleIdentifier: mappedBundleIdentifier,
            deviceIdentifier: deviceIdentifier,
            accountTeamID: account.teamID,
            certificateSerialNumber: certificateSerialNumber
        ) {
            return nil
        }

        do {
            _ = try await fileStore.fileURL(relativePath: signedPath)
            guard try await fileStore.validateSHA256(
                relativePath: signedPath,
                expected: expectedSHA256
            ) else { return nil }
        } catch {
            return nil
        }
        return try await installSignedIPA(
            app: app,
            signedPath: signedPath,
            bundleIdentifier: mappedBundleIdentifier,
            expirationDate: pendingExpiration,
            progress: progress,
            onInstallProgress: onInstallProgress
        )
    }

    private func installSignedIPA(
        app: AppRecord,
        signedPath: String,
        bundleIdentifier: String,
        expirationDate: Date,
        progress: @Sendable (SigningStage) async -> Void,
        onInstallProgress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> AppRecord {
        var updated = app
        // 安装期间申请后台保活，防止锁屏/切后台时 iOS 挂起网络连接
        let bgTask = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "Seal IPA Install")
        }
        defer {
            Task { @MainActor in
                UIApplication.shared.endBackgroundTask(bgTask)
            }
        }

        let signedData = try await fileStore.read(relativePath: signedPath)

        // 对齐官方 idevice：安装/校验以「成品包内 Info.plist 的真实 Bundle ID」为准，
        // 外部计算值仅在包内回读失败时回退，消除暂存路径 / ClientOptions / 包内 ID 不一致。
        let effectiveBundleID = SignedArtifactBundleIDReader.bundleIdentifier(in: signedData)
            ?? bundleIdentifier
        // 非标准包上回读值可能与外部计算值不同：以装到设备上的真实 ID 为准回写记录，
        // 否则后续续签用旧计算值做 lookup 会找不到应用，陷入重复签名。
        if effectiveBundleID != bundleIdentifier {
            updated.mappedBundleIdentifier = effectiveBundleID
        }

        // 安装前结构验证：确保签名后 IPA 包含 Payload/*.app、Info.plist、
        // embedded.mobileprovision、主可执行文件，避免把损坏包传到设备端
        // （设备端 installd 对结构损坏的包可能误报 MissingPackagePath 或模糊错误）。
        let validation = SignedArtifactValidator.validate(
            ipaData: signedData,
            expectedBundleID: effectiveBundleID
        )
        guard validation.isValid else {
            let reason = validation.failureReason ?? "签名后 IPA 结构验证未通过"
            let code = validation.failureCode ?? "SEAL-INSTALL-720"
            updated.state = app.state == .installed ? .installed : .signed
            updated.signedArtifactStatus = .installFailed
            updated.lastInstallFailureCode = code
            updated.lastInstallFailureReason = reason
            try await persistAppState(updated)
            throw ImportFailure(
                title: "安装前验证失败",
                reason: reason,
                recovery: "重新签名后再安装",
                code: code
            )
        }

        // 安装统一走本地通道（LocalDevVPN + Minimuxer + installation_proxy）。
        // OTA（itms-services）路线已按决策下线：安装一律经设备安装服务完成。
        if app.isSeal {
            // Persist the real signed-profile expiry before iOS replaces this running app.
            updated.state = .installed
            updated.signedArtifactStatus = .installed
            updated.lastInstallFailureCode = nil
            updated.lastInstallFailureReason = nil
            updated.expiryDate = expirationDate
            updated.lastInstalledAt = Date()
            try await appStore.save(updated)
            try await updateState(appID: app.id, stage: .pushing)
            await progress(.pushing)
            // 自更新必须在安装前清旧描述文件：installd 替换 Seal 后本进程即被终止，
            // 事后的异步清理基本活不到执行，Seal 自身 profile 因此只增不删。
            // 新 profile 随安装落设备，此刻凡匹配的都是旧文件；安装失败也不影响旧应用启动
            // （启动校验只看包内 embedded.mobileprovision，与设备 profile 列表无关）。
            // 匹配范围含：当前运行 ID + 记录目标 ID + 包内真实 ID，覆盖历史改 ID 残留。
            let cleanupSummary = await DeviceProfileCleaner.removeAllProfiles(
                for: [Bundle.main.bundleIdentifier, bundleIdentifier, effectiveBundleID].compactMap { $0 }
            )
            try? await logStore?.append(
                category: .installation,
                message: "自更新安装前清理：\(cleanupSummary.logMessage)"
            )
            try await installChannel.install(
                ipaData: signedData,
                bundleID: effectiveBundleID,
                isSelfReplacement: true,
                onProgress: onInstallProgress
            )
            updated.hasPendingSelfUpdateSource = false
            try await appStore.save(updated)
            removeStaleProfiles(signedData: signedData, effectiveBundleID: effectiveBundleID)
            return updated
        }

        do {
            try await updateState(appID: app.id, stage: .pushing)
            await progress(.pushing)
            try await installChannel.install(
                ipaData: signedData,
                bundleID: effectiveBundleID,
                isSelfReplacement: false,
                onProgress: onInstallProgress
            )

            try await updateState(appID: app.id, stage: .verifying)
            await progress(.verifying)
            try await installChannel.verifyInstalled(bundleID: effectiveBundleID)

            updated.state = .installed
            updated.signedArtifactStatus = .installed
            updated.lastInstallFailureCode = nil
            updated.lastInstallFailureReason = nil
            updated.hasPendingSelfUpdateSource = false
            // 安装校验已通过 —— 此刻才允许把「设备上运行的构建」的顶层 profile 身份
            // 推进到刚装上的这一份（R08）。
            SignedArtifactSnapshot.advanceInstalled(
                of: &updated,
                bundleIdentifier: effectiveBundleID,
                expiryDate: expirationDate
            )
            updated.lastInstalledAt = Date()
            try await appStore.save(updated)
            removeStaleProfiles(signedData: signedData, effectiveBundleID: effectiveBundleID)
            return updated
        } catch {
            // An existing Bundle ID may belong to the previous signing generation.
            // Never convert an installation/verification/persistence failure into success
            // using lookup alone, and never clean profiles on this failure path.
            if error is CancellationError { throw CancellationError() }
            // Preserve the original rejection instead of replacing it with a connection error.
            if let importFailure = error as? ImportFailure {
                throw await installDiagnosticsAppended(importFailure, signedPath: signedPath)
            }
            let nsError = error as NSError
            let base = ImportFailure(
                title: "安装失败",
                reason: "安装未完成：\(nsError.localizedDescription)。如桌面已出现云下载图标但点击无法安装，通常是签名或描述文件问题，请检查 Apple ID 证书状态后重试。",
                recovery: "重新安装",
                code: "SEAL-INSTALL-702b"
            )
            throw await installDiagnosticsAppended(base, signedPath: signedPath)
        }
    }

    /// 安装成功后清理设备端「同一 Bundle ID」的旧描述文件，保留刚安装的新 profile。
    /// 免费账号 7 天续签/反复重签会在设备端累积 profile，旧文件过期可能误导后续校验。
    /// 全程「最佳努力」：读不到新 profile UUID 或任何一步失败都静默跳过，绝不阻断安装结果。
    private func removeStaleProfiles(signedData: Data, effectiveBundleID: String) {
        guard let profileUUID = SignedArtifactProfileReader.embeddedProfileUUID(in: signedData) else {
            return
        }
        Task {
            let summary = await DeviceProfileCleaner.removeStaleProfiles(
                for: effectiveBundleID,
                keeping: profileUUID
            )
            try? await logStore?.append(
                category: .installation,
                message: "安装后旧描述文件清理（\(effectiveBundleID)）：\(summary.logMessage)"
            )
        }
    }

    /// 安装失败时把自诊断信息（Seal 构建号 + 签名包结构摘要）附加到失败原因，
    /// 使日志导出无需传输 IPA 即可还原安装时的包结构（Frameworks 目录、
    /// 根目录 framework 等），用于远程定位 installd discovery 类错误。
    private func installDiagnosticsAppended(
        _ failure: ImportFailure,
        signedPath: String
    ) async -> ImportFailure {
        var parts: [String] = []
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            parts.append("Seal构建\(build)")
        }
        guard let url = try? await fileStore.fileURL(relativePath: signedPath),
              let archive = try? Archive(url: url, accessMode: .read) else {
            parts.append("签名包不可读")
            return ImportFailure(
                title: failure.title,
                reason: failure.reason + "【诊断】" + parts.joined(separator: "；"),
                recovery: failure.recovery,
                code: failure.code
            )
        }
        var entryCount = 0
        var hasFrameworksEntry = false
        var rootFrameworkNames: Set<String> = []
        for entry in archive {
            entryCount += 1
            let path = entry.path
            if path.contains("/Frameworks") { hasFrameworksEntry = true }
            let components = path.split(separator: "/")
            if components.count == 3, components.first == "Payload",
               components[2].hasSuffix(".framework") {
                rootFrameworkNames.insert(String(components[2]))
            }
        }
        parts.append("IPA条目\(entryCount)")
        parts.append("Frameworks条目:\(hasFrameworksEntry ? "有" : "无")")
        if rootFrameworkNames.isEmpty == false {
            parts.append("根framework:\(rootFrameworkNames.joined(separator: ","))")
        }
        return ImportFailure(
            title: failure.title,
            reason: failure.reason + "【诊断】" + parts.joined(separator: "；"),
            recovery: failure.recovery,
            code: failure.code
        )
    }

    private func validateAccountSession(
        account: AppleAccountRecord,
        secret: AccountSecret,
        selectedAccountID: UUID
    ) async throws {
        guard secret.accountIdentifier == account.accountIdentifier else {
            throw Self.failure(
                reason: "本地 Keychain 凭据与当前 Apple ID 记录不一致。",
                recovery: "重新验证 Apple ID",
                code: "SEAL-AUTH-106"
            )
        }

        guard account.teamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw Self.failure(
                reason: "此 Apple ID 没有可用 Team ID，无法创建 App ID 或证书。",
                recovery: "前往 developer.apple.com 同意开发者协议后重试，或改用其他 Apple ID",
                code: "SEAL-AUTH-109"
            )
        }
    }

    private func normalizeCachedCertificateState(
        account: AppleAccountRecord,
        secret: AccountSecret
    ) async throws -> (account: AppleAccountRecord, secret: AccountSecret) {
        var updatedAccount = account
        var updatedSecret = secret
        var accountChanged = false

        let localCertificateSerial: String? = {
            guard let p12 = secret.certificateP12,
                  let certificate = try? ALTCertificate(p12Data: p12, password: nil) else {
                return nil
            }
            return certificate.serialNumber
        }()
        let storedSerial = secret.certificateSerialNumber?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasUsableLocalPrivateKey = {
            guard let storedSerial, storedSerial.isEmpty == false,
                  let localCertificateSerial else { return false }
            return storedSerial.caseInsensitiveCompare(localCertificateSerial) == .orderedSame
        }()

        if hasUsableLocalPrivateKey == false,
           secret.certificateSerialNumber != nil || secret.certificateP12 != nil {
            try await keychain.clearSigningMaterial(accountID: account.id)
            updatedSecret.certificateP12 = nil
            updatedSecret.certificateSerialNumber = nil
            updatedSecret.certificateMachineIdentifier = nil
            updatedAccount.certificateSerialNumber = nil
            updatedAccount.selectedCertificateSerialNumber = nil
            accountChanged = true
        } else {
            if updatedAccount.certificateSerialNumber != storedSerial {
                updatedAccount.certificateSerialNumber = storedSerial
                accountChanged = true
            }
            if updatedAccount.selectedCertificateSerialNumber != storedSerial {
                updatedAccount.selectedCertificateSerialNumber = storedSerial
                accountChanged = true
            }
        }

        if accountChanged {
            try await accountRepository.save(updatedAccount)
        }
        return (updatedAccount, updatedSecret)
    }

    private func persistAppState(_ app: AppRecord) async throws {
        do {
            try await appStore.save(app)
        } catch {
            throw Self.failure(
                reason: "签名状态未能写入本机数据库。",
                recovery: "检查本机存储空间后重试",
                code: "SEAL-SIGN-DB-001"
            )
        }
    }

    private func persistAccountState(_ account: AppleAccountRecord) async throws {
        do {
            try await accountRepository.save(account)
        } catch {
            throw Self.failure(
                reason: "Apple ID 状态未能写入本机数据库。",
                recovery: "检查本机存储空间后重试",
                code: "SEAL-AUTH-DB-001"
            )
        }
    }

    private func updateState(appID: UUID, stage: SigningStage) async throws {
        guard var app = try await appStore.fetchAll().first(where: {
            $0.id == appID
        }) else { return }
        app.state = stage.appState
        try await appStore.save(app)
    }

    private static func failure(
        reason: String,
        recovery: String,
        code: String
    ) -> ImportFailure {
        ImportFailure(
            title: Self.title(for: code),
            reason: reason,
            recovery: recovery,
            code: code
        )
    }

    /// 按错误码模块段给报错一个贴合语义的 title，避免所有错误都显示「无法完成签名」。
    private static func title(for code: String) -> String {
        if code == "SEAL-APPID-DEVICELIMIT" { return "应用数量已达上限" }
        if code.hasPrefix("SEAL-INSTALL-") { return "安装失败" }
        if code.hasPrefix("SEAL-AUTH-DB-") || code.hasPrefix("SEAL-SIGN-DB-") { return "本机数据错误" }
        if code.hasPrefix("SEAL-AUTH-") { return "无法使用账号" }
        if code.hasPrefix("SEAL-PAIR-") { return "设备配对失败" }
        if code.hasPrefix("SEAL-CERT-") { return "证书处理失败" }
        if code.hasPrefix("SEAL-APPID-") { return "应用标识被拒" }
        if code.hasPrefix("SEAL-BUNDLE-") { return "Bundle ID 冲突" }
        return "无法完成签名"
    }

    private static let freeAccountDeviceLimit = 3

    /// 免费 Apple ID 每台设备最多同时安装 3 个自签应用（含 Seal 自身）。
    /// 超限时 installd 只返回模糊错误且伴随长时间重传转圈，这里按本机已安装记录提前拦截。
    /// 上限是设备级（跨不同 Apple ID / team 累计，非每账号 3 个），计数逻辑见下方。
    private func enforceFreeAccountInstallLimit(
        app: AppRecord,
        account: AppleAccountRecord,
        bypassFreeAccountDeviceLimit: Bool = false
    ) async throws {
        guard account.isFreeTeam == true else { return }
        // 用户已在 Lara 完成 3-App Bypass 时跳过本机预检，交回 installd 最终裁决。
        guard bypassFreeAccountDeviceLimit == false else { return }
        // Apple 的「free developer profile」上限是设备级：一台设备上所有用免费 Apple ID
        // 签名的应用加总最多 3 个（跨不同 Apple ID / team 累计，不是每个账号 3 个）。
        // 此前按 signingTeamID/accountID 过滤只数到当前账号，会漏掉用其它免费账号签的
        // 应用。日志证实：微信/Seal/黄豆短剧分属不同 team，仍被 installd 以
        // ApplicationVerificationFailed 拒绝。
        let paidAccountIDs = try await accountRepository.fetchAll()
            .filter { $0.isFreeTeam == false }
            .map(\.id)
        let occupied = try await appStore.fetchAll()
            .filter { $0.id != app.id && $0.belongsInInstalledList }
            .filter { record in
                // 明确由付费账号签名的应用不占免费名额；其余（免费账号 / 记录缺失）计入。
                guard let accountID = record.accountID else { return true }
                return paidAccountIDs.contains(accountID) == false
            }
            .count
        guard occupied >= Self.freeAccountDeviceLimit else { return }
        throw Self.failure(
            reason: "这台设备已用免费 Apple ID 同时安装了 \(Self.freeAccountDeviceLimit) 个自签应用（跨 Apple ID 累计，含 Seal 自身），已达到 Apple 上限。",
            recovery: "先在手机上卸载一个已安装的自签应用后重试。",
            code: "SEAL-APPID-DEVICELIMIT"
        )
    }

    /// 签名目标 Bundle ID 与已安装应用冲突（导入与已安装 IPA 相同、签名后 Bundle ID 一致）时
    /// 提前拦截。iOS 无法并存同 Bundle ID 的应用：继续安装只会覆盖同名应用并在列表里残留
    /// 第二条相同身份的记录，同时文件系统也会多出一份重复文件夹。这里按 `userIdentityKeys`
    /// （签名后的 mapped/preferred Bundle ID）比对，排除自身记录，续签不受影响。
    private func enforceBundleIdentifierUniqueness(
        app: AppRecord,
        targetBundleIdentifier: String
    ) async throws {
        let normalizedTarget = targetBundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedTarget.isEmpty == false else { return }
        // Seal 自身更新属于覆盖安装（升级版本），不是第三方同名冲突，直接放行。
        // 第三方同 Bundle ID 仍走下方去重拦截。
        if app.isSeal { return }
        let records = try await appStore.fetchAll()
        guard let conflicting = records.first(where: { record in
            record.id != app.id
                && record.belongsInInstalledList
                && record.userIdentityKeys.contains(normalizedTarget)
        }) else { return }
        throw Self.failure(
            reason: "Bundle ID「\(targetBundleIdentifier)」已被手机上的「\(conflicting.displayName)」占用，同一 Bundle ID 不能同时安装两个应用。",
            recovery: "在签名页改用不同的 Bundle ID 后重试，或先在手机上卸载「\(conflicting.displayName)」。",
            code: "SEAL-BUNDLE-004"
        )
    }
}

private extension SigningStage {
    var appState: AppState {
        switch self {
        case .waitingForChannel: .waitingForInstallChannel
        case .preparingAccount: .waitingForAccount
        case .preparingCertificate: .preparingCertificate
        case .preparingAppID, .preparingProfiles: .preparingProfiles
        case .signing: .signing
        case .pushing, .installing: .installing
        case .verifying: .verifying
        }
    }
}
