import Foundation
import UIKit
@preconcurrency import AltSign

enum ApplePortalSigningStage {
    case account
    case device
    case certificate
    case appID
    case provisioningProfile
    case signing
    case packaging
}

enum ApplePortalAppIDResolver {
    static func matches(
        existingBundleIdentifier: String,
        requestedBundleIdentifier: String
    ) -> Bool {
        existingBundleIdentifier.caseInsensitiveCompare(requestedBundleIdentifier) == .orderedSame
    }
}

enum ApplePortalSigningFailure {
    static func make(stage: ApplePortalSigningStage, error: Error) -> ImportFailure {
        if AppleServiceFailurePolicy.isRateLimited(error) {
            return AppleServiceFailurePolicy.rateLimitedFailure(underlying: error)
        }
        if AppleServiceFailurePolicy.isNetworkError(error) {
            return AppleServiceFailurePolicy.networkFailure(
                title: "连不上 Apple",
                reason: "连不上 Apple 开发者服务器，请检查网络或梯子。已保存的 Apple ID 和已签应用不受影响。",
                code: "SEAL-NET-102"
            )
        }
        let nsError = error as NSError
        let diagnostic = "[\(nsError.domain) \(nsError.code)] \(nsError.localizedDescription)"
        let details: (title: String, reason: String, recovery: String, code: String)
        switch stage {
        case .account:
            if nsError.code == 1100 || diagnostic.contains("session has expired") || diagnostic.contains("1100") {
                details = (
                    "登录过期了",
                    "这个 Apple ID 的登录过期了，需要重新验证一次才能继续签名或续签。",
                    "去「我的」重新验证",
                    "SEAL-AUTH-107"
                )
            } else {
                details = (
                    "Apple 账户操作失败",
                    "Apple 返回了无法分类的账户错误。账号状态未改变。\nApple 返回：\(diagnostic)",
                    "重试",
                    "SEAL-VERIFY-500"
                )
            }
        case .device:
            details = (
                "设备注册失败",
                "Apple 返回：设备注册未完成。\nApple 返回：\(diagnostic)",
                "检查设备配对",
                "SEAL-DEVICE-203"
            )
        case .certificate:
            return certificateFailure(error: error, diagnostic: diagnostic)
        case .appID:
            return appIDFailure(error: error, diagnostic: diagnostic)
        case .provisioningProfile:
            details = (
                "描述文件失败",
                "Apple 返回：描述文件生成失败。\nApple 返回：\(diagnostic)",
                "重试",
                "SEAL-PROFILE-303"
            )
        case .signing:
            details = (
                "签名失败",
                "签名工具未能完成当前 IPA。\n详情：\(diagnostic)",
                "重试",
                "SEAL-SIGN-501"
            )
        case .packaging:
            details = (
                "打包失败",
                "签名后的 IPA 无法完成打包。\n详情：\(diagnostic)",
                "检查设备剩余存储空间后重试；仍失败请重新签名",
                "SEAL-SIGN-502"
            )
        }
        return ImportFailure(
            title: details.title,
            reason: details.reason,
            recovery: details.recovery,
            code: details.code
        )
    }

    fileprivate static func appIDFailure(error: Error, diagnostic: String) -> ImportFailure {
        let nsError = error as NSError
        let rawMessage = nsError.localizedDescription
        let normalized = rawMessage.lowercased()

        // Apple 会话过期（1100）在 App ID 创建阶段也会出现（如抖音签名时），
        // 必须与账户阶段一致归为 SEAL-AUTH-107，否则会落进下方「App ID 创建失败」
        // 分支被误报成网络/标注问题。
        if nsError.code == 1100 || normalized.contains("session has expired") || diagnostic.contains("1100") {
            return ImportFailure(
                title: "登录过期了",
                reason: "这个 Apple ID 的登录过期了，需要重新验证一次才能继续签名或续签。",
                recovery: "去「我的」重新验证",
                code: "SEAL-AUTH-107"
            )
        }

        if nsError.code == 3011
            || normalized.contains("bundle identifier is unavailable")
            || normalized.contains("already registered by another developer account")
            || normalized.contains("bundle identifier unavailable") {
            return ImportFailure(
                title: "Bundle ID 已被占用",
                reason: "这个 Bundle ID 已被其他开发者账号注册，当前账号无法使用。\nApple 返回：\(diagnostic)",
                recovery: "更换一个新的 Bundle ID，或使用注册该 Bundle ID 的原账号签名",
                code: "SEAL-APPID-302"
            )
        }

        // 免费账号 App ID 数量上限（7 天内最多注册 10 个）。
        // 覆盖 AltStore 老错误码 1009，以及新一代 AltSign 使用的 Apple 原生错误码 3013
        //（过去漏匹配 3013，落进下方通用「App ID 创建失败」分支，被误报成网络问题）。
        if Self.isAppIDRegistrationLimit(error, normalized: normalized) {
            return ImportFailure(
                title: "7 天内最多注册 10 个 App ID",
                reason: "已达到 App ID 数量上限。App ID 无法手动删除，7 天后自动过期。请到「已签名 App」查看过期时间，或换其他 Apple ID 签名。",
                recovery: "App ID 无法手动删除，7 天后自动过期；或换其他 Apple ID 签名",
                code: "SEAL-APPID-304"
            )
        }

        return ImportFailure(
            title: "App ID 创建失败",
            reason: "Apple 服务器未能创建该应用的 App ID。Apple 返回：\(diagnostic)",
            recovery: "若提示会话已过期，请先前往「我的」页面重新验证 Apple ID；否则检查网络后重试，或尝试更换 Bundle ID / 使用其他开发者账号",
            code: "SEAL-APPID-303"
        )
    }

    /// 免费账号「7 天内最多注册 10 个 App ID」的识别。
    ///
    /// 关键点：该限制是 **Apple 的 7 天滑动窗口计数**，不是「当前存活的 App ID 数量」，
    /// 所以 `fetchAppIDs` 返回的 `existing.count`（当前存活数）少也可能命中 ——
    /// 本地预检放行后，真实 `addAppID` 仍会报错，必须靠这里兜底识别，避免误报成网络问题。
    /// 错误码时代差异：AltStore 老实现用 1009，新一代 AltSign 用 Apple 原生 3013。
    fileprivate static func isAppIDRegistrationLimit(
        _ error: Error,
        normalized: String
    ) -> Bool {
        let code = (error as NSError).code
        if code == 1009 || code == 3013 { return true }
        return normalized.contains("maximum")
            || normalized.contains("limit")
            || normalized.contains("too many")
            || normalized.contains("no more")
            || normalized.contains("every 7 days")
            || normalized.contains("10 app ids")
            || (normalized.contains("app id")
                && (normalized.contains("exceed") || normalized.contains("reached") || normalized.contains("register")))
    }

    private static func certificateFailure(error: Error, diagnostic: String) -> ImportFailure {
        let nsError = error as NSError
        let rawMessage = nsError.localizedDescription
        let normalized = rawMessage.lowercased()

        if let failure = CertificateRequestFailurePolicy.requestFailure(error: error, limitCode: "SEAL-CERT-204a") {
            return failure
        }

        if normalized.contains("network")
            || normalized.contains("timed out")
            || normalized.contains("cannot connect")
            || nsError.domain == NSURLErrorDomain {
            return ImportFailure(
                title: "证书服务连接失败",
                reason: "无法连接 Apple 证书服务（网络超时或无法连接）。Apple 返回：\(diagnostic)",
                recovery: "检查网络后重试",
                code: "SEAL-CERT-205"
            )
        }

        if normalized.contains("unauthorized")
            || normalized.contains("authentication")
            || normalized.contains("session")
            || normalized.contains("forbidden") {
            return ImportFailure(
                title: "账号需要重新验证",
                reason: "Apple 返回：认证状态无效",
                recovery: "前往「我的」页面重新登录该 Apple ID",
                code: "SEAL-AUTH-102c"
            )
        }

        return ImportFailure(
            title: "证书准备失败",
            reason: "Apple 服务器未能准备好签名证书。\nApple 返回：\(diagnostic)",
            recovery: "检查网络后重试",
            code: "SEAL-CERT-203"
        )
    }

}

/// AltSign 回调式 API 的 async 包装 + 超时保护。
///
/// 意图：AltSign 内部 URLSession 没有设置超时，Apple 服务器不响应时回调永远不触发，UI 会永久卡住。
///
/// **必须用 `HardTimeout`（非结构化任务竞速），不能用 `withThrowingTaskGroup`。**
/// 任务组退出前必须等所有子任务结束，`cancelAll()` 只能设置协作取消标记；ALTAppleAPI 的回调一旦
/// 不返回，子任务就永远不结束，超时错误便永远抛不出来 —— 等于没有超时，UI 无限等待。
/// 本仓 `HardTimeout` 就是为修掉这个写法而写的（同类实现见 `AppleAccountClient.withTimeout`、
/// `MinimuxerInstallChannel.withHardTimeout`）。此处此前仍是 task group 写法，2026-09-14 修正。
func withAppleTimeout<T: Sendable>(
    _ seconds: UInt64 = 20,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    do {
        return try await HardTimeout.run(seconds: TimeInterval(seconds), operation)
    } catch is HardTimeout.TimeoutError {
        // 文案保持不变：上层按这条 description 归类，改动会波及错误码口径。
        throw URLError(.timedOut, userInfo: [
            NSLocalizedDescriptionKey: "Apple 服务器响应超时（\(seconds) 秒），请检查网络或代理后重试"
        ])
    }
}

actor ApplePortalSigningService {
    private let anisetteProvider: any AnisetteProvider
    private let signingWorkspace: SigningWorkspace
    private let accountClient: AppleAccountClient
    // 对齐 AltStore：防止并发签名时重复创建 App Group
    // App Group 操作通过 actor 串行化；批量签名为串行循环，无并发创建风险

    init(
        anisetteProvider: any AnisetteProvider = AnisetteV3Client(),
        signingWorkspace: SigningWorkspace = SigningWorkspace()
    ) {
        self.anisetteProvider = anisetteProvider
        self.signingWorkspace = signingWorkspace
        self.accountClient = AppleAccountClient(anisetteProvider: anisetteProvider)
    }


    func sign(
        app: AppRecord,
        account: AppleAccountRecord,
        secret: AccountSecret,
        deviceIdentifier: String,
        originalIPAURL: URL,
        workspaceRoot: URL,
        targetBundleIdentifier: String? = nil,
        preferredIconData: Data? = nil,
        selectedCertificateSerialNumber: String? = nil,
        allowDroppingExtensions: Bool,
        persistSigningMaterial: @escaping @Sendable (AccountSecret, String) async throws -> Void,
        progress: @Sendable (SigningStage) async -> Void
    ) async throws -> PortalSigningResult {
        let secretState = SigningSecretState(secret)
        let persistence: @Sendable (AccountSecret, String) async throws -> Void = {
            updatedSecret, serialNumber in
            try await persistSigningMaterial(updatedSecret, serialNumber)
            await secretState.update(updatedSecret)
        }

        do {
            return try await signOnce(
                app: app,
                account: account,
                secret: await secretState.value(),
                deviceIdentifier: deviceIdentifier,
                originalIPAURL: originalIPAURL,
                workspaceRoot: workspaceRoot,
                targetBundleIdentifier: targetBundleIdentifier,
                preferredIconData: preferredIconData,
                selectedCertificateSerialNumber: selectedCertificateSerialNumber,
                allowDroppingExtensions: allowDroppingExtensions,
                persistSigningMaterial: persistence,
                progress: progress
            )
        } catch let failure as ImportFailure where failure.code == "SEAL-AUTH-107" {
            // Apple 会话过期（1100）：签名/续签时是 LocalDevVPN 环境，
            // 自动重登需要访问 Apple 认证服务器，网络不匹配必败。
            // 直接提示用户去「我的」页面重新验证（那里用户会自己挂梯子），不标记 ID 失效。
            throw Self.failure(
                title: "Apple ID 会话已过期",
                reason: "该 Apple ID 的登录状态已过期。签名过程中无法重新认证（网络环境不匹配），请前往「我的」页面重新验证该 Apple ID 后再签名。",
                recovery: "去「我的」页面重新验证 Apple ID",
                code: "SEAL-AUTH-107"
            )
        } catch let failure as ImportFailure where Self.shouldRetryWithFreshSigningCertificate(failure) {
            var refreshedSecret = await secretState.value()
            refreshedSecret.certificateP12 = nil
            refreshedSecret.certificateSerialNumber = nil
            refreshedSecret.certificateMachineIdentifier = nil
            await secretState.update(refreshedSecret)
            let retryWorkspaceRoot = workspaceRoot.appending(path: "FreshCertificateRetry-\(UUID().uuidString)")
            return try await signOnce(
                app: app,
                account: account,
                secret: refreshedSecret,
                deviceIdentifier: deviceIdentifier,
                originalIPAURL: originalIPAURL,
                workspaceRoot: retryWorkspaceRoot,
                targetBundleIdentifier: targetBundleIdentifier,
                preferredIconData: preferredIconData,
                selectedCertificateSerialNumber: nil,
                allowDroppingExtensions: allowDroppingExtensions,
                persistSigningMaterial: persistence,
                progress: progress
            )
        } catch ALTAppleAPIError.invalidAnisetteData {
            await anisetteProvider.resetProvisioning()
            do {
                return try await signOnce(
                    app: app,
                    account: account,
                    secret: await secretState.value(),
                    deviceIdentifier: deviceIdentifier,
                    originalIPAURL: originalIPAURL,
                    workspaceRoot: workspaceRoot,
                    targetBundleIdentifier: targetBundleIdentifier,
                    preferredIconData: preferredIconData,
                    selectedCertificateSerialNumber: selectedCertificateSerialNumber,
                    allowDroppingExtensions: allowDroppingExtensions,
                    persistSigningMaterial: persistence,
                    progress: progress
                )
            } catch let failure as ImportFailure {
                throw failure
            } catch {
                throw Self.failure(
                    title: "签名请求失败",
                    reason: "重设签名环境后，Apple 服务器仍未能完成签名请求（可能网络不稳定或 Apple 服务暂时不可用）。",
                    recovery: "检查网络后稍后重试；如持续失败请查看日志",
                    code: "SEAL-SIGN-503"
                )
            }
        }
    }

    private static func shouldRetryWithFreshSigningCertificate(_ failure: ImportFailure) -> Bool {
        if failure.code == "SEAL-PROFILE-313" { return true }
        let message = "\(failure.title) \(failure.reason) \(failure.recovery)"
        return failure.title.localizedCaseInsensitiveContains("描述文件校验失败")
            && message.localizedCaseInsensitiveContains("证书")
    }

    private func signOnce(
        app: AppRecord,
        account: AppleAccountRecord,
        secret: AccountSecret,
        deviceIdentifier: String,
        originalIPAURL: URL,
        workspaceRoot: URL,
        targetBundleIdentifier: String?,
        preferredIconData: Data?,
        selectedCertificateSerialNumber: String?,
        allowDroppingExtensions: Bool,
        persistSigningMaterial: @escaping @Sendable (AccountSecret, String) async throws -> Void,
        progress: @Sendable (SigningStage) async -> Void
    ) async throws -> PortalSigningResult {
        var stage: ApplePortalSigningStage = .account
        do {
            try Task.checkCancellation()
            await progress(.preparingAccount)
            let anisette = try await anisetteProvider.fetch()
            let session = ALTAppleAPISession(
                dsid: secret.dsid,
                authToken: secret.authToken,
                anisetteData: anisette,
                xcodeVersion: AppleAccountClient.xcodeVersion
            )
            let altAccount = ALTAccount()
            altAccount.appleID = secret.email
            altAccount.identifier = secret.accountIdentifier
            let teams = try await fetchTeams(account: altAccount, session: session)
            try Task.checkCancellation()
            guard let team = teams.first(where: { $0.identifier == account.teamID }) else {
                throw Self.failure(
                    title: "Team 不匹配",
                    reason: "Apple 返回的团队列表中已找不到已保存的 Team ID；Seal 不会静默切换到其他 Team。",
                    recovery: "选择 Team",
                    code: "SEAL-AUTH-112d"
                )
            }
            let deviceName = await MainActor.run { UIDevice.current.name }
            stage = .device
            _ = try await ensureDevice(
                identifier: deviceIdentifier,
                name: deviceName,
                team: team,
                session: session
            )
            try Task.checkCancellation()

            await progress(.preparingCertificate)
            stage = .certificate
            let identity = try await signingIdentity(
                account: account,
                isSeal: app.isSeal,
                secret: secret,
                team: team,
                session: session,
                deviceName: deviceName,
                selectedCertificateSerialNumber: selectedCertificateSerialNumber,
                persistSigningMaterial: persistSigningMaterial
            )
            try Task.checkCancellation()

            // 大 IPA 峰值磁盘空间：解压 ~1x + ldid 临时文件 ~1x + 输出 IPA ~1x
            // 微信 400MB 需 ~1.2GB，盛世天下 580MB 需 ~1.8GB。空间不足会导致
            // ldid.cpp(538) 写入失败或 ZIPFoundation DataError，提前检查给出明确提示。
            do {
                let ipaAttrs = try FileManager.default.attributesOfItem(atPath: originalIPAURL.path)
                let ipaSize = (ipaAttrs[.size] as? NSNumber)?.int64Value ?? 0
                if ipaSize > 0 {
                    let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                    if let docDir,
                       let freeAttrs = try? FileManager.default.attributesOfFileSystem(forPath: docDir.path),
                       let freeBytes = (freeAttrs[.systemFreeSize] as? NSNumber)?.int64Value {
                        let requiredBytes = ipaSize * 4 + 200 * 1024 * 1024 // 4x + 200MB 余量
                        if freeBytes < requiredBytes {
                            let freeGB = Double(freeBytes) / 1_000_000_000
                            let requiredGB = Double(requiredBytes) / 1_000_000_000
                            throw Self.failure(
                                title: "存储空间不足",
                                reason: String(format: "签名此 IPA 约需 %.1fGB 临时空间，当前剩余 %.1fGB。大 IPA 解压、签名、打包各需一份副本。", requiredGB, freeGB),
                                recovery: "清理手机存储空间后重试",
                                code: "SEAL-SIGN-405"
                            )
                        }
                    }
                }
            }

            stage = .packaging
            let prepared = try signingWorkspace.prepare(
                ipaURL: originalIPAURL,
                workspaceRoot: workspaceRoot,
                originalBundleID: app.originalBundleIdentifier,
                teamID: team.identifier,
                targetMainBundleID: targetBundleIdentifier,
                preferredDisplayName: app.preferredDisplayName,
                preferredIconData: preferredIconData
            )
            try Task.checkCancellation()

            await progress(.preparingAppID)
            stage = .appID
            let profilePreparation = try await provisioningProfiles(
                mappings: prepared.bundleIDMappings,
                mappedMainBundleID: prepared.mappedMainBundleID,
                appName: app.displayName,
                appURL: prepared.appURL,
                workspace: prepared,
                allowDroppingExtensions: allowDroppingExtensions,
                team: team,
                session: session,
                progress: progress
            )
            try Task.checkCancellation()
            guard profilePreparation.profiles.contains(where: {
                $0.bundleIdentifier == prepared.mappedMainBundleID
            }) else {
                throw Self.failure(
                    title: "主应用描述文件缺失",
                    reason: "Apple 未返回主应用（\(prepared.mappedMainBundleID)）的签名描述文件。",
                    recovery: "检查网络后重试；如持续失败请重新导入 IPA",
                    code: "SEAL-PROFILE-305"
                )
            }

            await progress(.signing)
            stage = .signing
            try await signApp(
                at: prepared.appURL,
                p12Data: identity.secret.certificateP12,
                mainBundleID: prepared.mappedMainBundleID,
                profiles: profilePreparation.profiles
            )
            try Task.checkCancellation()

            let profileBindings = try validateEmbeddedProfiles(
                in: prepared,
                teamID: team.identifier,
                certificateSerialNumber: identity.certificate.serialNumber,
                deviceIdentifier: deviceIdentifier,
                requestedEntitlements: profilePreparation.requestedEntitlements
            )
            guard let mainBinding = profileBindings[prepared.mappedMainBundleID] else {
                throw Self.failure(
                    title: "描述文件校验失败",
                    reason: "签名完成后未找到主应用的 embedded.mobileprovision：\(prepared.mappedMainBundleID)。",
                    recovery: "重新获取描述文件",
                    code: "SEAL-PROFILE-317a"
                )
            }

            stage = .packaging
            let signedIPAURL = prepared.rootURL.appending(path: "Signed.ipa")
            try signingWorkspace.package(prepared, outputURL: signedIPAURL)

            return PortalSigningResult(
                mappedMainBundleID: prepared.mappedMainBundleID,
                mappedBundleIdentifiers: prepared.bundleIDMappings,
                expirationDate: mainBinding.expirationDate,
                signedIPAURL: signedIPAURL,
                updatedSecret: identity.secret,
                certificateSerialNumber: identity.certificate.serialNumber,
                certificateMachineIdentifier: identity.certificate.machineIdentifier,
                deviceIdentifier: deviceIdentifier,
                teamID: team.identifier,
                profileBindings: profileBindings,
                droppedExtensionBundleIdentifiers:
                    profilePreparation.droppedExtensionBundleIdentifiers
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch ALTAppleAPIError.invalidAnisetteData {
            throw ALTAppleAPIError(.invalidAnisetteData)
        } catch ALTAppleAPIError.maximumAppIDLimitReached {
            throw Self.failure(
                title: "App ID 名额已满",
                reason: "Apple 返回 App ID 数量已达到账号上限。",
                recovery: "使用其他 Bundle ID 或开发者账号。",
                code: "SEAL-APPID-301"
            )
        } catch ALTAppleAPIError.incorrectCredentials {
            throw Self.failure(
                title: "Apple ID 凭据被拒绝",
                reason: "Apple 已明确拒绝当前登录凭据（可能密码已更改或账号被锁定）。",
                recovery: "前往「我的」页面重新登录该 Apple ID",
                code: "SEAL-AUTH-102d"
            )
        } catch ALTAppleAPIError.authenticationHandshakeFailed {
            throw Self.failure(
                title: "登录握手未通过",
                reason: "与 Apple 的登录握手失败（常见原因：设备环境数据无效或系统时间偏差）。",
                recovery: "核对系统时间后重试；仍失败请到「我的」页面重新验证该 Apple ID",
                code: "SEAL-AUTH-102e"
            )
        } catch let failure as ImportFailure {
            throw failure
        } catch {
            throw ApplePortalSigningFailure.make(stage: stage, error: error)
        }
    }

    private func fetchTeams(
        account: ALTAccount,
        session: ALTAppleAPISession
    ) async throws -> [ALTTeam] {
        let box: LegacyBox<[ALTTeam]> = try await withAppleTimeout {
            try await withCheckedThrowingContinuation {
                continuation in
                let callback = ContinuationBox(continuation)
                ALTAppleAPI.shared.fetchTeams(for: account, session: session) { teams, error in
                    Self.resume(callback, value: teams, error: error)
                }
            }
        }
        return box.value
    }

    private func ensureDevice(
        identifier: String,
        name: String,
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws -> ALTDevice {
        let devicesBox: LegacyBox<[ALTDevice]> = try await withAppleTimeout {
            try await withCheckedThrowingContinuation {
                continuation in
                let callback = ContinuationBox(continuation)
                ALTAppleAPI.shared.fetchDevices(
                    for: team,
                    types: [.iphone, .ipad],
                    session: session
                ) { devices, error in
                    Self.resume(callback, value: devices, error: error)
                }
            }
        }
        if let device = devicesBox.value.first(where: { $0.identifier == identifier }) {
            return device
        }
        let deviceBox: LegacyBox<ALTDevice> = try await withAppleTimeout {
            try await withCheckedThrowingContinuation {
                continuation in
                let callback = ContinuationBox(continuation)
                ALTAppleAPI.shared.registerDevice(
                    name: name,
                    identifier: identifier,
                    type: .iphone,
                    team: team,
                    session: session
                ) { device, error in
                    Self.resume(callback, value: device, error: error)
                }
            }
        }
        return deviceBox.value
    }

    /// 复用证书的最低剩余有效期：必须覆盖免费账号描述文件的 7 天寿命。
    /// 只查「当前未过期」会把明天就到期的证书签进新包，次日 iOS 判「尚未验证」闪退。

    private static func certificateReusable(_ certificate: ALTCertificate, now: Date = Date()) -> Bool {
        SigningCertificateMaterialPolicy.reuseStatus(certificate, now: now) == .reusable
    }

    private func signingIdentity(
        account: AppleAccountRecord,
        isSeal: Bool,
        secret: AccountSecret,
        team: ALTTeam,
        session: ALTAppleAPISession,
        deviceName: String,
        selectedCertificateSerialNumber: String?,
        persistSigningMaterial: @escaping @Sendable (AccountSecret, String) async throws -> Void
    ) async throws -> SigningIdentity {
        // 快速路径：本地证书可读时先做"本地 + 可选校验"——能拉到 Apple 证书列表就比对，
        // 证书仍有效才复用本地证书；拉不到（大陆 IP 时限流很慢）则退回本地证书保持提速。
        // 否则本地证书已失效，落回慢速路径重新申请，避免旧证书配新描述文件触发 Rork 报
        // "Signing identity is not authorized by one of the provisioning profiles"。
        let effectiveSerial = selectedCertificateSerialNumber ?? secret.certificateSerialNumber
        if let serial = effectiveSerial,
           serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           let local = SigningCertificateMaterialPolicy.availableCertificate(secret: secret, serialNumber: serial),
           let machineID = secret.certificateMachineIdentifier,
           machineID.isEmpty == false {
            local.machineIdentifier = machineID
            if let certificates = try? await fetchCertificates(team: team, session: session) {
                // 在生效列表且剩余有效期覆盖 7 天 profile 寿命才可复用：只查列表/只看当下未过期，
                // 会把「明天就到期的证书」签进新包，次日被 iOS 判「尚未验证」闪退。
                if certificates.contains(where: {
                    SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber) == SigningCertificateSelectionPolicy.normalizedSerialNumber(serial)
                }), Self.certificateReusable(local) {
                    return SigningIdentity(
                        certificate: local,
                        secret: secret.activated(
                            for: serial,
                            machineIdentifier: local.machineIdentifier
                        ) ?? secret
                    )
                }
                // 证书已不在 Apple 生效列表、已过期或剩余寿命不足 7 天，落到慢速路径重新申请新证书
            } else {
                // 网络失败/限流：退回本地证书，保留提速效果。
                // 但免费账号证书可能已过期或临近到期；复用会让 iOS 判定"尚未验证"导致闪退，
                // 因此剩余寿命不足 7 天时必须落入慢速路径重新申请，不得复用。
                if Self.certificateReusable(local) {
                    return SigningIdentity(
                        certificate: local,
                        secret: secret.activated(
                            for: serial,
                            machineIdentifier: local.machineIdentifier
                        ) ?? secret
                    )
                }
            }
        }

        // 慢速路径：本地证书不可用，从 Apple 服务器获取证书列表
        let certificates = try await fetchCertificates(team: team, session: session)
        try Task.checkCancellation()

        if let selectedCertificateSerialNumber,
           let remote = certificates.first(where: {
               SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber) == SigningCertificateSelectionPolicy.normalizedSerialNumber(selectedCertificateSerialNumber)
           }),
           let local = SigningCertificateMaterialPolicy.availableCertificate(secret: secret, serialNumber: selectedCertificateSerialNumber),
           Self.certificateReusable(local) {
            local.machineIdentifier = remote.machineIdentifier
            return SigningIdentity(
                certificate: local,
                secret: secret.activated(
                    for: selectedCertificateSerialNumber,
                    machineIdentifier: remote.machineIdentifier
                ) ?? secret
            )
        }

        if let serial = secret.certificateSerialNumber,
           let remote = certificates.first(where: {
               SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber) == SigningCertificateSelectionPolicy.normalizedSerialNumber(serial)
           }),
           let local = SigningCertificateMaterialPolicy.availableCertificate(secret: secret, serialNumber: serial),
           Self.certificateReusable(local) {
            local.machineIdentifier = remote.machineIdentifier
            return SigningIdentity(
                certificate: local,
                secret: secret.activated(
                    for: serial,
                    machineIdentifier: remote.machineIdentifier
                ) ?? secret
            )
        }

        // 根治「创建新证书覆盖旧 P12」的问题：新版本会按 serial 保留每一张
        // 自动创建过的 P12。当前绑定已被撤销时，先在这些历史材料里寻找仍在 Apple
        // 生效列表的证书；找到就自动修复绑定并无感复用，不申请新证书、不撤销旧 App。
        for remote in certificates {
            guard let local = SigningCertificateMaterialPolicy.availableCertificate(secret: secret, serialNumber: remote.serialNumber),
                  Self.certificateReusable(local) else { continue }
            local.machineIdentifier = remote.machineIdentifier
            return SigningIdentity(
                certificate: local,
                secret: secret.activated(
                    for: remote.serialNumber,
                    machineIdentifier: remote.machineIdentifier
                ) ?? secret
            )
        }

        // 只对当前运行包、同一 Team 且缺少本机私钥的外部身份允许首次接管。
        // 先尝试创建而不撤销当前 Seal；Apple 明确拒绝后说明恢复路径。
        let runningMetadata = await MainActor.run { isSeal ? SelfAppMetadata.current() : nil }
        let localPrivateKeySerials = Set(certificates.compactMap { certificate -> String? in
            SigningCertificateMaterialPolicy.availableCertificate(secret: secret, serialNumber: certificate.serialNumber) == nil
                ? nil : certificate.serialNumber
        })
        let externalSealSerial = SigningCertificateMaterialPolicy.externalSealSerial(
            isSeal: isSeal,
            teamID: account.teamID,
            runningTeamID: runningMetadata?.signingTeamIdentifier,
            runningSerials: runningMetadata?.certificateSerialNumbers ?? [],
            remoteSerials: certificates.map(\.serialNumber),
            localPrivateKeySerials: localPrivateKeySerials,
            expectedSerialNumber: selectedCertificateSerialNumber ?? secret.certificateSerialNumber
        )
        let expectedSerial = selectedCertificateSerialNumber ?? secret.certificateSerialNumber
        if let expectedSerial,
           expectedSerial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            let remoteContainsExpected = certificates.contains {
                SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber) == SigningCertificateSelectionPolicy.normalizedSerialNumber(expectedSerial)
            }
            if remoteContainsExpected,
               SigningCertificateMaterialPolicy.availableCertificate(secret: secret, serialNumber: expectedSerial) == nil,
               externalSealSerial == nil {
                throw Self.missingLocalPrivateKeyFailure(serialNumber: expectedSerial)
            }
            if remoteContainsExpected == false, externalSealSerial == nil {
                // 账号记录仍指向一张已经被撤销/删除的证书。不能把「绑定过的旧证书
                // 不存在」伪装成「请再申请一张」：当前账号可能正好只剩另一张仍被
                // 已安装 App 使用的证书，盲目申请只会再次撞数量上限。
                throw Self.staleCertificateBindingFailure(
                    serialNumber: expectedSerial,
                    availableCertificateCount: certificates.count
                )
            }
        }

        do {
            return try await createSigningIdentity(
                secret: secret,
                team: team,
                session: session,
                deviceName: deviceName,
                persistSigningMaterial: persistSigningMaterial
            )
        } catch let failure as ImportFailure where failure.code == "SEAL-CERT-204b" && externalSealSerial != nil {
            throw Self.externalSealIdentityFailure(underlying: failure)
        }
    }

    static func externalSealIdentityFailure(underlying: ImportFailure) -> ImportFailure {
        Self.failure(
            title: "Seal 尚未建立本机签名身份",
            reason: "当前 Seal 使用外部工具签发的证书，本机没有对应私钥。登录同一个 Apple ID 不会同步该私钥；为保护当前 Seal，已保留其证书。尝试创建本机证书时，Apple 拒绝了新增请求。\n\(underlying.reason)",
            recovery: "请先用原电脑签名工具为 Seal 续期以保持可用，再在电脑端检查该账号证书状态。待账号允许新建证书后，回到 Seal 再次续签；本页重复检查或重新登录不会补回外部私钥。",
            code: "SEAL-CERT-221"
        )
    }

    static func missingLocalPrivateKeyFailure(serialNumber: String) -> ImportFailure {
        let normalizedSerial = SigningCertificateSelectionPolicy.normalizedSerialNumber(serialNumber)
        return Self.failure(
            title: "本机缺少证书私钥",
            reason: "Apple 账号下仍有证书（序列号末尾 …\(normalizedSerial.suffix(12))），但本机没有可用的 P12 私钥。已安装的 App 仍可能继续运行，因为它们使用的是包内已签入的证书；新签名不能只靠 Apple 服务器上的公钥证书完成。",
            recovery: "请在原签名工具检查这张证书的签名身份；重新登录 Apple ID 无法恢复缺失的本机私钥。",
            code: "SEAL-CERT-204c"
        )
    }

    static func staleCertificateBindingFailure(
        serialNumber: String,
        availableCertificateCount: Int
    ) -> ImportFailure {
        let normalizedSerial = SigningCertificateSelectionPolicy.normalizedSerialNumber(serialNumber)
        let remainingText = availableCertificateCount == 0
            ? "Apple 账号当前没有可用的开发证书记录"
            : "Apple 账号还有 \(availableCertificateCount) 张证书，但它们不是本机当前绑定的那张"
        return Self.failure(
            title: "本机绑定的证书已不存在",
            reason: "本机记录绑定的证书序列号末尾为 …\(normalizedSerial.suffix(12))，Apple 侧已找不到它。\(remainingText)。已安装 App 仍可能继续运行，但不能用另一张证书的公钥冒充本机私钥签名。",
            recovery: "请在「我的」中核对账号证书清单及本机签名身份；若当前 Seal 来自电脑工具，请先用原工具保持 Seal 可用，再处理证书绑定。",
            code: "SEAL-CERT-204d"
        )
    }

    private func createSigningIdentity(
        secret: AccountSecret,
        team: ALTTeam,
        session: ALTAppleAPISession,
        deviceName: String,
        persistSigningMaterial: @escaping @Sendable (AccountSecret, String) async throws -> Void
    ) async throws -> SigningIdentity {
        let requested: ALTCertificate
        do {
            let created = try await addCertificate(
                team: team,
                session: session,
                deviceName: deviceName
            )
            requested = created
        } catch {
            if let failure = CertificateRequestFailurePolicy.requestFailure(error: error) { throw failure }
            throw error
        }

        do {
            // Cancellation after creation must enter the new-certificate cleanup path.
            try Task.checkCancellation()
            guard let certificate = try await waitForCreatedCertificate(
                serialNumber: requested.serialNumber,
                team: team,
                session: session
            ) else {
                throw Self.failure(
                    title: "证书创建结果不一致",
                    reason: "Apple 已返回新证书，但重新同步后无法确认该证书。",
                    recovery: "重新同步证书",
                    code: "SEAL-CERT-209a"
                )
            }
            let fullCert = ALTCertificate(x509: certificate, privateKey: requested.privateKey)
            guard let p12 = try? fullCert.unencryptedP12Data() else {
                throw Self.failure(
                    title: "无法保存新证书",
                    reason: "Apple 已创建证书，但本机无法将证书与私钥合成 P12。",
                    recovery: "重试签名",
                    code: "SEAL-CERT-202a"
                )
            }

            var updatedSecret = secret
            updatedSecret.storeCertificateMaterial(
                p12: p12,
                serialNumber: certificate.serialNumber,
                machineIdentifier: certificate.machineIdentifier
            )

            try await persistSigningMaterial(updatedSecret, certificate.serialNumber)
            return SigningIdentity(certificate: fullCert, secret: updatedSecret)
        } catch {
            let cleanedUp = await cleanUpNewCertificate(
                serialNumber: requested.serialNumber,
                certificate: requested,
                team: team,
                session: session,
                secret: secret
            )
            guard cleanedUp else {
                throw Self.failure(
                    title: "证书清理未完成",
                    reason: "签名证书已创建，但后续处理失败；自动撤销该证书也失败，可能残留一个占用名额的证书。",
                    recovery: "请稍后重试",
                    code: "SEAL-CERT-215c"
                )
            }
            if let failure = error as? ImportFailure { throw failure }
            throw error
        }
    }

    private func waitForCreatedCertificate(
        serialNumber: String,
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws -> ALTX509Certificate? {
        let maxAttempts = 10
        let retryDelayNanoseconds: UInt64 = 500_000_000
        var lastFetchError: Error?
        var hadSuccessfulFetch = false

        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()

            do {
                let certificates = try await fetchCertificates(team: team, session: session)
                hadSuccessfulFetch = true
                if let certificate = certificates.first(where: {
                    $0.serialNumber.caseInsensitiveCompare(serialNumber) == .orderedSame
                }) {
                    return certificate
                }
            } catch {
                lastFetchError = error
            }

            if attempt + 1 < maxAttempts {
                try await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }

        if hadSuccessfulFetch {
            return nil
        }
        if let lastFetchError {
            throw lastFetchError
        }
        return nil
    }
    private func cleanUpNewCertificate(
        serialNumber: String,
        certificate: ALTCertificate,
        team: ALTTeam,
        session: ALTAppleAPISession,
        secret: AccountSecret
    ) async -> Bool {
        if (try? await revokeCertificate(certificate.x509, team: team, session: session)) != nil {
            return true
        }

        await anisetteProvider.resetProvisioning()
        guard let anisette = try? await anisetteProvider.fetch() else { return false }
        let refreshedSession = ALTAppleAPISession(
            dsid: secret.dsid,
            authToken: secret.authToken,
            anisetteData: anisette,
            xcodeVersion: AppleAccountClient.xcodeVersion
        )
        guard let certificates = try? await fetchCertificates(
            team: team,
            session: refreshedSession
        ) else {
            return false
        }
        guard let exactCertificate = certificates.first(where: {
            $0.serialNumber.caseInsensitiveCompare(serialNumber) == .orderedSame
        }) else {
            return true
        }
        return (try? await revokeCertificate(
            exactCertificate,
            team: team,
            session: refreshedSession
        )) != nil
    }

    private func fetchCertificates(
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws -> [ALTX509Certificate] {
        let box: LegacyBox<[ALTX509Certificate]> = try await withAppleTimeout {
            try await withCheckedThrowingContinuation {
                continuation in
                let callback = ContinuationBox(continuation)
                ALTAppleAPI.shared.fetchCertificates(for: team, session: session) {
                    certificates, error in
                    Self.resume(callback, value: certificates, error: error)
                }
            }
        }
        return box.value
    }

    /// 创建签名证书（写 API）。
    ///
    /// 超时的语义和读 API 完全不同，这里必须区别对待：
    /// - 请求超时**不代表失败** —— Apple 可能已经建好证书，只是响应没回来；
    /// - 即使建好了也**拿不回来** —— 私钥由 AltSign 在本地生成、只随响应返回，响应一丢就不可恢复。
    ///
    /// 所以这里绝不盲目重试（会多占一个证书名额），也绝不自动撤销（可能撤掉正要用的证书），
    /// 而是超时后**对账一次**远端证书列表，把「到底留下了什么」如实告诉用户（见 `OrphanReconciliation`）。
    private func addCertificate(
        team: ALTTeam,
        session: ALTAppleAPISession,
        deviceName: String
    ) async throws -> ALTCertificate {
        let machineName = certificateMachineName(deviceName: deviceName)
        do {
            let box: LegacyBox<ALTCertificate> = try await withAppleTimeout(30) {
                try await withCheckedThrowingContinuation {
                    continuation in
                    let callback = ContinuationBox(continuation)
                    ALTAppleAPI.shared.addCertificate(
                        machineName: machineName,
                        to: team,
                        session: session
                    ) { certificate, error in
                        Self.resume(callback, value: certificate, error: error)
                    }
                }
            }
            return box.value
        } catch {
            guard Self.isTimeoutError(error) else { throw error }
            let reconciliation = await reconcileCertificateCreation(
                machineName: machineName,
                team: team,
                session: session
            )
            throw Self.certificateCreationUnknownFailure(reconciliation)
        }
    }

    /// 写 API 超时后的对账结论。三种结果必须分开，不能把「无法确认」当成「没有创建」。
    /// 非 private：错误码与文案由单测直接断言（超时路径无法用真实 ALTAppleAPI 触发）。
    enum OrphanReconciliation {
        /// 远端列表里没有本次 machineName 对应的证书 —— 可判定创建未生效，重试是安全的。
        case none
        /// 远端确实多出了这张证书，但私钥已随丢失的响应一起没了；只能如实告知，
        /// 回收交给后续限额触发时的无感清理（证书页已只读，不再提供手动撤销入口）。
        case found(serialNumber: String)
        /// 对账请求本身也失败，无法判定。必须按「未知」处理。
        case inconclusive
    }

    /// 写 API 超时（`withAppleTimeout` 统一抛出的 `URLError.timedOut`）。
    static func isTimeoutError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    /// 超时对账：按本次请求使用的 machineName 查远端证书列表。
    /// machineName 现在是固定友好名（如 `Seal-iPhone`），同一账号下可能有多张同名证书，
    /// 因此取「创建时间最新」的一张作为本次请求的产物，避免误认旧证书。
    private func reconcileCertificateCreation(
        machineName: String,
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async -> OrphanReconciliation {
        guard let certificates = try? await fetchCertificates(team: team, session: session) else {
            return .inconclusive
        }
        let matches = certificates.filter { $0.machineName == machineName }
        guard let match = matches.max(by: { $0.creationDate < $1.creationDate }) else {
            return .none
        }
        return .found(serialNumber: match.serialNumber)
    }

    static func certificateCreationUnknownFailure(
        _ reconciliation: OrphanReconciliation
    ) -> ImportFailure {
        switch reconciliation {
        case let .found(serialNumber):
            return ImportFailure(
                title: "证书已创建但私钥已丢失",
                reason: "创建证书的请求超时，Apple 实际已创建证书（序列号 \(serialNumber)），但响应丢失，私钥无法取回，这张证书不能用于签名。",
                recovery: "请稍后重试",
                code: "SEAL-CERT-209b"
            )
        case .none:
            return ImportFailure(
                title: "证书创建未生效",
                reason: "创建证书的请求超时；对账后确认 Apple 并未创建该证书。",
                recovery: "重试签名",
                code: "SEAL-CERT-209c"
            )
        case .inconclusive:
            return ImportFailure(
                title: "证书创建结果未知",
                reason: "创建证书的请求超时，且对账请求同样失败，无法确认 Apple 是否已创建证书。此时盲目重试会多占一个证书名额。",
                recovery: "先到「我的」→「签名证书」确认是否多出一张证书，再决定是否重试",
                code: "SEAL-CERT-209d"
            )
        }
    }

    private func certificateMachineName(deviceName: String) -> String {
        let sanitizedDevice = deviceName
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        let devicePart = sanitizedDevice.isEmpty ? "Device" : String(sanitizedDevice.prefix(18))
        return "Seal-\(devicePart)"
    }

    private func revokeCertificate(
        _ certificate: ALTX509Certificate,
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws {
        try await withAppleTimeout {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let callback = ContinuationBox(continuation)
                ALTAppleAPI.shared.revoke(certificate, for: team, session: session) {
                    success, error in
                    if success {
                        callback.resume()
                    } else {
                        callback.resume(
                            throwing: error ?? URLError(.badServerResponse)
                        )
                    }
                }
            }
        }
    }

    private func provisioningProfiles(
        mappings: [String: String],
        mappedMainBundleID: String,
        appName: String,
        appURL: URL,
        workspace: PreparedSigningWorkspace,
        allowDroppingExtensions: Bool,
        team: ALTTeam,
        session: ALTAppleAPISession,
        progress: @Sendable (SigningStage) async -> Void
    ) async throws -> ProfilePreparation {
        guard let mainApplication = ALTApplication(fileURL: appURL) else {
            throw Self.failure(
                title: "无法签名",
                reason: "应用结构无效，无法从 \(appURL.path) 解析出主应用（可能缺少 Info.plist 或可执行文件）。",
                recovery: "检查 IPA",
                code: "SEAL-SIGN-404a"
            )
        }
        var applications = [mainApplication.bundleIdentifier: mainApplication]
        for appExtension in mainApplication.appExtensions {
            applications[appExtension.bundleIdentifier] = appExtension
        }

        var existing = try await fetchAppIDs(team: team, session: session)

        // 不做「existing.count >= 10 就硬拦」的本地预检（原 SEAL-APPID-305）：
        // Apple 的真实上限是「7 天内最多注册 10 个 App ID」（滑动窗口），不是「当前存活 App ID ≤ 10」。
        // 7 天窗口滚动后，老 App ID 仍在存活列表、却已不算进当周窗口，账号可合法攒到 >10 个，
        // Apple 也照常放行注册——用 existing.count 一刀切会误拦。改为交给 Apple 裁决：真超限时
        // addAppID 返回 1009/3013，由 appIDFailure/isAppIDRegistrationLimit 兜底归类成 SEAL-APPID-304。
        // 主 App / 扩展若确实无法新建，Phase 1 会抛错或自动跳过签不了的扩展，语意不变。

        var preparedAppIDs: [(original: String, mapped: String, appID: ALTAppID)] = []
        var requestedEntitlements: [String: [String: ProvisioningEntitlementValue]] = [:]
        var droppedExtensionBundleIdentifiers: [String] = []

        // Phase 1: only read/create/update App IDs. No provisioning profile is fetched here.
        for (originalBundleID, mappedBundleID) in mappings.sorted(by: { $0.key < $1.key }) {
            do {
                try Task.checkCancellation()
                var appID: ALTAppID
                if let found = existing.first(where: {
                    ApplePortalAppIDResolver.matches(
                        existingBundleIdentifier: $0.bundleIdentifier,
                        requestedBundleIdentifier: mappedBundleID
                    )
                }) {
                    appID = found
                } else {
                    do {
                        let createdBox: LegacyBox<ALTAppID> =
                            try await withAppleTimeout {
                                try await withCheckedThrowingContinuation { continuation in
                                let callback = ContinuationBox(continuation)
                                    // App ID 名称必须是 ASCII，Apple 不允许中文等非 ASCII 字符（错误码 3009）
                                    // 官方 AltStore 用 Bundle ID 作为 App ID 名称，保证 ASCII 且唯一
                                    let appIDName = String(mappedBundleID.prefix(50))
                                    ALTAppleAPI.shared.addAppID(
                                        withName: appIDName,
                                        bundleIdentifier: mappedBundleID,
                                        team: team,
                                        session: session
                                    ) { created, error in
                                        Self.resume(callback, value: created, error: error)
                                    }
                                }
                            }
                        appID = createdBox.value
                    } catch ALTAppleAPIError.bundleIdentifierUnavailable {
                        let refreshed = try await fetchAppIDs(team: team, session: session)
                        guard let found = refreshed.first(where: {
                            ApplePortalAppIDResolver.matches(
                                existingBundleIdentifier: $0.bundleIdentifier,
                                requestedBundleIdentifier: mappedBundleID
                            )
                        }) else {
                            throw ALTAppleAPIError(.bundleIdentifierUnavailable)
                        }
                        appID = found
                    }
                    existing.append(appID)
                }

                if let application = applications[originalBundleID] {
                    let entitlementSource = filteredAppIDEntitlements(from: application, team: team)
                    var entitlementValues: [String: ProvisioningEntitlementValue] = [:]
                    for (entitlement, value) in entitlementSource {
                        guard let converted = ProvisioningEntitlementValue.make(from: value) else {
                            throw Self.failure(
                                title: "应用权限无法解析",
                                reason: "\(mappedBundleID) 的权限 \(entitlement.rawValue) 包含无法校验的值类型。",
                                recovery: "检查 IPA 权限或使用支持该能力的账号",
                                code: "SEAL-ENTITLEMENT-403"
                            )
                        }
                        entitlementValues[entitlement.rawValue] = converted
                    }
                    requestedEntitlements[mappedBundleID] = entitlementValues
                    // 扩展 features 更新失败时降级为空 features 重试，主 App 失败则直接报错
                    do {
                        appID = try await updateFeatures(
                            appID: appID,
                            application: application,
                            team: team,
                            session: session
                        )
                        if team.type != .free {
                            try await assignAppGroups(
                                appID: appID,
                                application: application,
                                team: team,
                                session: session
                            )
                        }
                    } catch where mappedBundleID != mappedMainBundleID {
                        // 扩展降级：清空 features，用空 entitlements 继续签名
                        requestedEntitlements[mappedBundleID] = [:]
                    }
                }
                preparedAppIDs.append((originalBundleID, mappedBundleID, appID))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard mappedBundleID != mappedMainBundleID else { throw error }
                guard allowDroppingExtensions else {
                    // 扩展 App ID 创建失败时，先识别是否 App ID 7 天限额（1009/3013）：
                    // 限额是全局的，「移除扩展」也救不了（且 Seal 自身必须保留 SealTunnel 扩展），
                    // 应透传准确原因，而不是包成误导性的「移除扩展后重试」。
                    if ApplePortalSigningFailure.isAppIDRegistrationLimit(error, normalized: (error as NSError).localizedDescription.lowercased()) {
                        let ns = error as NSError
                        throw ApplePortalSigningFailure.appIDFailure(
                            error: error,
                            diagnostic: "[\(ns.domain) \(ns.code)] \(ns.localizedDescription)"
                        )
                    }
                    throw Self.failure(
                        title: "签名失败",
                        reason: "Apple 返回：扩展无法创建 App ID",
                        recovery: "移除扩展后重试",
                        code: "SEAL-EXT-401"
                    )
                }
                try signingWorkspace.removeExtension(
                    mappedBundleIdentifier: mappedBundleID,
                    from: workspace
                )
                requestedEntitlements.removeValue(forKey: mappedBundleID)
                droppedExtensionBundleIdentifiers.append(originalBundleID)
            }
        }

        // Phase 2: App IDs are settled; now fetch/generate real provisioning profiles.
        await progress(.preparingProfiles)
        var profiles: [ALTProvisioningProfile] = []
        for preparedAppID in preparedAppIDs {
            do {
                try Task.checkCancellation()
                let profile = try await fetchProvisioningProfile(
                    for: preparedAppID.appID,
                    team: team,
                    session: session
                )
                profiles.append(profile)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as ImportFailure {
                if preparedAppID.mapped == mappedMainBundleID { throw failure }
                guard allowDroppingExtensions else { throw failure }
                try signingWorkspace.removeExtension(
                    mappedBundleIdentifier: preparedAppID.mapped,
                    from: workspace
                )
                requestedEntitlements.removeValue(forKey: preparedAppID.mapped)
                droppedExtensionBundleIdentifiers.append(preparedAppID.original)
            } catch {
                if preparedAppID.mapped == mappedMainBundleID {
                    throw ApplePortalSigningFailure.make(
                        stage: .provisioningProfile,
                        error: error
                    )
                }
                guard allowDroppingExtensions else {
                    throw Self.failure(
                        title: "签名失败",
                        reason: "Apple 返回：扩展无法生成描述文件",
                        recovery: "移除扩展后重试",
                        code: "SEAL-EXT-401a"
                    )
                }
                try signingWorkspace.removeExtension(
                    mappedBundleIdentifier: preparedAppID.mapped,
                    from: workspace
                )
                requestedEntitlements.removeValue(forKey: preparedAppID.mapped)
                droppedExtensionBundleIdentifiers.append(preparedAppID.original)
            }
        }

        return ProfilePreparation(
            profiles: profiles,
            requestedEntitlements: requestedEntitlements,
            droppedExtensionBundleIdentifiers: Array(Set(droppedExtensionBundleIdentifiers))
        )
    }

    private func fetchAppIDs(
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws -> [ALTAppID] {
        let box: LegacyBox<[ALTAppID]> = try await withAppleTimeout {
            try await withCheckedThrowingContinuation {
                continuation in
                let callback = ContinuationBox(continuation)
                ALTAppleAPI.shared.fetchAppIDs(for: team, session: session) { appIDs, error in
                    Self.resume(callback, value: appIDs, error: error)
                }
            }
        }
        return box.value
    }

    private func fetchProvisioningProfile(
        for appID: ALTAppID,
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws -> ALTProvisioningProfile {
        // 对齐 AltStore 官方实现：先获取，再尝试删除旧描述文件，删除成功则重新获取生成新的。
        // 免费账号从 2023-03-20 起无法删除描述文件，每次 fetch 会自动重新生成，
        // 因此删除失败时直接返回已获取的描述文件即可。
        let firstBox: LegacyBox<ALTProvisioningProfile> = try await withAppleTimeout(30) {
            try await withCheckedThrowingContinuation {
                continuation in
                let callback = ContinuationBox(continuation)
                ALTAppleAPI.shared.fetchProvisioningProfile(
                    for: appID,
                    deviceType: .iphone,
                    team: team,
                    session: session
                ) { profile, error in
                    Self.resume(callback, value: profile, error: error)
                }
            }
        }
        let profile = firstBox.value

        // 尝试删除旧描述文件（付费账号可删除，免费账号会失败）
        let deleteSucceeded: Bool
        do {
            try await withAppleTimeout(15) {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    let callback = ContinuationBox(continuation)
                    ALTAppleAPI.shared.deleteProvisioningProfile(
                        profile,
                        for: team,
                        session: session
                    ) { success, error in
                        if let error {
                            callback.resume(throwing: error)
                        } else if success {
                            callback.resume()
                        } else {
                            callback.resume(throwing: ALTAppleAPIError.unknown())
                        }
                    }
                }
            }
            deleteSucceeded = true
        } catch {
            // 免费账号无法删除，直接返回已获取的描述文件
            deleteSucceeded = false
        }

        guard deleteSucceeded else {
            // 免费账号无法删除描述文件（2023-03-20 起 Apple 限制），
            // 但删除操作本身会触发 Apple 重新生成描述文件，因此必须再 fetch 一次，
            // 确保返回的是删除操作后的新生成结果，而不是第一次 fetch 到的旧文件。
            let regeneratedBox: LegacyBox<ALTProvisioningProfile> = try await withAppleTimeout(30) {
                try await withCheckedThrowingContinuation {
                    continuation in
                    let callback = ContinuationBox(continuation)
                    ALTAppleAPI.shared.fetchProvisioningProfile(
                        for: appID,
                        deviceType: .iphone,
                        team: team,
                        session: session
                    ) { profile, error in
                        Self.resume(callback, value: profile, error: error)
                    }
                }
            }
            return regeneratedBox.value
        }

        // 删除成功（付费账号），重新获取生成新的描述文件
        let secondBox: LegacyBox<ALTProvisioningProfile> = try await withAppleTimeout(30) {
            try await withCheckedThrowingContinuation {
                continuation in
                let callback = ContinuationBox(continuation)
                ALTAppleAPI.shared.fetchProvisioningProfile(
                    for: appID,
                    deviceType: .iphone,
                    team: team,
                    session: session
                ) { profile, error in
                    Self.resume(callback, value: profile, error: error)
                }
            }
        }
        return secondBox.value
    }


    private func updateFeatures(
        appID: ALTAppID,
        application: ALTApplication,
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws -> ALTAppID {
        let filteredEntitlements = filteredAppIDEntitlements(
            from: application,
            team: team
        )
        var features: [ALTFeature: Any] = [:]
        for (entitlement, value) in filteredEntitlements {
            if let feature = ALTFeature(entitlement: entitlement) {
                features[feature] = value
            }
        }
        if team.type != .free,
           let groups = filteredEntitlements[.appGroups] as? [String],
           groups.isEmpty == false {
            features[.appGroups] = true
        }

        // If there is nothing Apple needs to toggle, keep the existing App ID as-is.
        // This avoids sending empty or signer-managed entitlement payloads that Apple
        // rejects as "provided parameters are invalid" for free accounts.
        guard features.isEmpty == false || filteredEntitlements.isEmpty == false else {
            return appID
        }

        guard let updated = appID.copy() as? ALTAppID else {
            throw Self.failure(
                title: "无法签名",
                reason: "应用能力更新失败：Apple 返回的 App ID 无法复制，未能写入新的应用能力（如 App Groups、推送等权限）。",
                recovery: "检查网络后重试；如持续失败请重新导入 IPA",                code: "SEAL-PROFILE-304"
            )
        }
        updated.features = features
        updated.entitlements = filteredEntitlements
        do {
            return try await submitUpdatedAppID(updated, team: team, session: session)
        } catch {
            guard Self.isInvalidAppIDParameterError(error),
                  team.type == .free,
                  let fallback = appID.copy() as? ALTAppID else {
                throw error
            }
            fallback.features = [:]
            fallback.entitlements = [:]
            return try await submitUpdatedAppID(fallback, team: team, session: session)
        }
    }

    private func filteredAppIDEntitlements(
        from application: ALTApplication,
        team: ALTTeam
    ) -> [ALTEntitlement: any Sendable] {
        let signerManagedEntitlements: Set<String> = [
            "application-identifier",
            "com.apple.developer.team-identifier",
            "keychain-access-groups",
            "get-task-allow"
        ]
        var filtered: [ALTEntitlement: any Sendable] = [:]
        for (entitlement, value) in application.entitlements {
            if signerManagedEntitlements.contains(entitlement.rawValue) {
                continue
            }
            if team.type == .free,
               ALTFreeDeveloperCanUseEntitlement(entitlement) == false {
                continue
            }
            if team.type == .free, entitlement == .appGroups {
                continue
            }
            filtered[entitlement] = value
        }
        return filtered
    }

    private func submitUpdatedAppID(
        _ updated: ALTAppID,
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws -> ALTAppID {
        let box: LegacyBox<ALTAppID> = try await withAppleTimeout {
            try await withCheckedThrowingContinuation {
                continuation in
                let callback = ContinuationBox(continuation)
                ALTAppleAPI.shared.update(
                    updated,
                    team: team,
                    session: session
                ) { appID, error in
                    Self.resume(callback, value: appID, error: error)
                }
            }
        }
        return box.value
    }

    private static func isInvalidAppIDParameterError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let normalized = "\(nsError.domain) \(nsError.code) \(nsError.localizedDescription) \(String(describing: error))".lowercased()
        return nsError.code == 3001
            || normalized.contains("3001")
            || normalized.contains("provided parameters are invalid")
    }

    private func assignAppGroups(
        appID: ALTAppID,
        application: ALTApplication,
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws {
        guard let originalGroups = application.entitlements[.appGroups] as? [String],
              originalGroups.isEmpty == false else { return }
        // App Group 操作通过 actor 串行化；批量签名为串行循环，无并发创建风险
        let mappedIdentifiers = originalGroups.map {
            signingWorkspace.bundleIDMapper.appGroupID(
                original: $0,
                teamID: team.identifier
            )
        }
        let fetchedBox: LegacyBox<[ALTAppGroup]> =
            try await withAppleTimeout {
                try await withCheckedThrowingContinuation { continuation in
                let callback = ContinuationBox(continuation)
                    ALTAppleAPI.shared.fetchAppGroups(for: team, session: session) {
                        groups, error in
                        Self.resume(callback, value: groups, error: error)
                    }
                }
            }
        var available = fetchedBox.value
        var assigned: [ALTAppGroup] = []
        for identifier in mappedIdentifiers {
            try Task.checkCancellation()
            if let existing = available.first(where: {
                $0.groupIdentifier == identifier
            }) {
                assigned.append(existing)
                continue
            }
            let suffix = identifier.split(separator: ".").last.map(String.init) ?? "Group"
            let createdBox: LegacyBox<ALTAppGroup> =
                try await withAppleTimeout {
                    try await withCheckedThrowingContinuation { continuation in
                    let callback = ContinuationBox(continuation)
                        ALTAppleAPI.shared.addAppGroup(
                            withName: "Seal Group \(suffix)",
                            groupIdentifier: identifier,
                            team: team,
                            session: session
                        ) { group, error in
                            Self.resume(callback, value: group, error: error)
                        }
                    }
                }
            available.append(createdBox.value)
            assigned.append(createdBox.value)
        }

        let groupsToAssign = assigned
        try await withAppleTimeout {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let callback = ContinuationBox(continuation)
                ALTAppleAPI.shared.assign(
                    appID,
                    to: groupsToAssign,
                    team: team,
                    session: session
                ) { success, error in
                    if success {
                        callback.resume()
                    } else {
                        callback.resume(
                            throwing: error ?? URLError(.badServerResponse)
                        )
                    }
                }
            }
        }
    }

    private func validateEmbeddedProfiles(
        in workspace: PreparedSigningWorkspace,
        teamID: String,
        certificateSerialNumber: String,
        deviceIdentifier: String,
        requestedEntitlements: [String: [String: ProvisioningEntitlementValue]]
    ) throws -> [String: ProvisioningProfileBinding] {
        let reader = ProvisioningProfileReader()
        var bindings: [String: ProvisioningProfileBinding] = [:]

        for target in try signingWorkspace.signedBundleTargets(in: workspace) {
            let profileURL = target.bundleURL.appending(path: "embedded.mobileprovision")
            guard FileManager.default.fileExists(atPath: profileURL.path) else {
                throw Self.failure(
                    title: "描述文件校验失败",
                    reason: "\(target.bundleIdentifier) 没有 embedded.mobileprovision。主应用和每个扩展都必须独立包含正确的描述文件。",
                    recovery: "重新获取描述文件",
                    code: "SEAL-PROFILE-318"
                )
            }
            let data = try Data(contentsOf: profileURL)
            let binding = try reader.binding(from: data)
                .validated(
                    expectedTeamID: teamID,
                    expectedBundleID: target.bundleIdentifier,
                    expectedCertificateSerialNumber: certificateSerialNumber,
                    expectedDeviceIdentifier: deviceIdentifier
                )
            try ProvisioningProfileBinding.validateEntitlements(
                requested: requestedEntitlements[target.bundleIdentifier] ?? [:],
                profile: binding.entitlements,
                bundleIdentifier: target.bundleIdentifier
            )
            bindings[target.bundleIdentifier] = binding
        }
        return bindings
    }

    private func signApp(
        at appURL: URL,
        p12Data: Data?,
        mainBundleID: String,
        profiles: [ALTProvisioningProfile]
    ) async throws {
        guard let p12Data, p12Data.isEmpty == false else {
            throw ApplePortalSigningFailure.make(
                stage: .signing,
                error: RorkAppSigner.SignError.missingCertificate
            )
        }

        // 用 AltSign 自己的 ALTCertificate 解析 P12（OpenSSL 实现，与上游一致）。
        // 不能用 iOS 原生 SecPKCS12Import（OpenSSL 生成的无密码 P12 报 errSecAuthFailed），
        // 也不能用 rork-sign 自带 PKCS12 解析器（与 Apple/OpenSSL 的 MAC KDF 不兼容）。
        let altCert: ALTCertificate
        do {
            altCert = try ALTCertificate(p12Data: p12Data, password: nil)
        } catch {
            throw ApplePortalSigningFailure.make(
                stage: .signing,
                error: RorkAppSigner.SignError.identityImportFailed(
                    "ALTCertificate 解析 P12 失败：\(error.localizedDescription)，请重新登录 Apple ID"
                )
            )
        }

        guard let certificateData = altCert.data, certificateData.isEmpty == false else {
            throw ApplePortalSigningFailure.make(
                stage: .signing,
                error: RorkAppSigner.SignError.missingCertificate
            )
        }
        let privateKeyData = altCert.privateKey

        // 在 actor 上先提取 Sendable 数据（ALTProvisioningProfile 是 ObjC 非 Sendable 类型）
        let materials = profiles.map {
            RorkAppSigner.ProfileMaterial(bundleID: $0.bundleIdentifier, data: $0.data)
        }

        // 防御性校验：签名前确认主描述文件确实授权了当前证书。若证书已在 Apple 侧被
        // 轮换/吊销，这里用明确的序列号对照报错，避免落到 Rork 的模糊报错。
        // 序列号跨来源比对须先归一化（AltSign 剥前导 0、Security 框架保留前导 0），
        // 否则同一证书会因前导 0 差异被误判为“已被轮换”。
        let chosenSerial = SigningCertificateSelectionPolicy.normalizedSerialNumber(altCert.serialNumber)
        let mainAuthData = materials.first(where: {
            $0.bundleID.caseInsensitiveCompare(mainBundleID) == .orderedSame
        })?.data ?? materials.first?.data
        if let mainAuthData,
           let authDetails = try? ProvisioningProfileReader().details(from: mainAuthData) {
            let authorizedSerials = authDetails.certificateSerialNumbers
                .map { SigningCertificateSelectionPolicy.normalizedSerialNumber($0) }
            if authorizedSerials.contains(chosenSerial) == false {
                throw ApplePortalSigningFailure.make(
                    stage: .signing,
                    error: RorkAppSigner.SignError.signFailed(
                        "所选证书 \(chosenSerial) 不在主描述文件授权列表 [\(authorizedSerials.joined(separator: ", "))] 中，证书可能已在 Apple 侧被轮换"
                    )
                )
            }
        }
        // rork-sign 是 CPU 密集型同步操作，丢到后台线程，避免长时间占用 actor
        try await Task.detached(priority: .userInitiated) {
            // 对齐 AltStore：签名前把每个描述文件的 appGroups 写入对应 bundle 的 Info.plist
            let reader = ProvisioningProfileReader()
            for material in materials {
                let groups: [String]
                if let details = try? reader.details(from: material.data),
                   case let .array(values) = details.entitlements["com.apple.security.application-groups"] {
                    groups = values.compactMap { v in
                        if case let .string(s) = v { return s }
                        return nil
                    }
                } else {
                    groups = []
                }
                guard groups.isEmpty == false else { continue }

                let bundleURL: URL
                if material.bundleID.caseInsensitiveCompare(mainBundleID) == .orderedSame {
                    bundleURL = appURL
                } else {
                    // 扩展：在 PlugIns 目录中按 CFBundleIdentifier 匹配
                    let pluginsURL = appURL.appendingPathComponent("PlugIns")
                    guard let pluginFiles = try? FileManager.default.contentsOfDirectory(
                        at: pluginsURL, includingPropertiesForKeys: nil
                    ) else { continue }
                    guard let matched = pluginFiles.first(where: { ext in
                        guard ext.pathExtension == "appex" else { return false }
                        let info = NSDictionary(
                            contentsOf: ext.appendingPathComponent("Info.plist")
                        )
                        let bid = info?["CFBundleIdentifier"] as? String
                        return bid?.caseInsensitiveCompare(material.bundleID) == .orderedSame
                    }) else { continue }
                    bundleURL = matched
                }

                let infoURL = bundleURL.appendingPathComponent("Info.plist")
                guard let infoDictionary = NSMutableDictionary(contentsOf: infoURL) else { continue }
                infoDictionary["ALTAppGroups"] = groups

                // 文件提供者扩展：替换 NSExtensionFileProviderDocumentGroup
                if var extInfo = infoDictionary["NSExtension"] as? [String: Any],
                   let originalGroup = extInfo["NSExtensionFileProviderDocumentGroup"] as? String {
                    let matched = groups.first(where: { $0.contains(originalGroup) }) ?? groups.first
                    if let matched {
                        extInfo["NSExtensionFileProviderDocumentGroup"] = matched
                        infoDictionary["NSExtension"] = extInfo
                    }
                }

                try? infoDictionary.write(to: infoURL)
            }

            // 从主应用描述文件提取映射后的 appGroups，传给 RorkSigner 确保 entitlements 中 appGroups 正确
            let mainProfileData = materials.first(where: {
                $0.bundleID.caseInsensitiveCompare(mainBundleID) == .orderedSame
            })?.data ?? materials.first?.data
            let appGroups: [String]
            if let data = mainProfileData,
               let details = try? ProvisioningProfileReader().details(from: data),
               case let .array(values) = details.entitlements["com.apple.security.application-groups"] {
                appGroups = values.compactMap { v in
                    if case let .string(s) = v { return s }
                    return nil
                }
            } else {
                appGroups = []
            }

            try RorkAppSigner.signAppBundle(
                at: appURL,
                certificateData: certificateData,
                privateKeyData: privateKeyData,
                mainBundleID: mainBundleID,
                profiles: materials,
                appGroupIdentifiers: appGroups
            )
        }.value
    }

    /// 统一转发 AltSign 回调结果。
    ///
    /// 第一参数是 `ContinuationBox`（而非裸 `CheckedContinuation`）：ALTAppleAPI 可能
    /// 成功/失败都回调、或在超时之后迟到回调，裸 continuation 第二次 resume 会直接
    /// 触发 `SWIFT TASK CONTINUATION MISUSE` 致命崩溃。盒子保证只有第一个结果生效。
    private static func resume<Value>(
        _ callback: ContinuationBox<LegacyBox<Value>>,
        value: Value?,
        error: Error?
    ) {
        if let value {
            callback.resume(returning: LegacyBox(value))
        } else {
            callback.resume(throwing: error ?? URLError(.badServerResponse))
        }
    }

    private static func failure(
        title: String,
        reason: String,
        recovery: String,
        code: String
    ) -> ImportFailure {
        ImportFailure(title: title, reason: reason, recovery: recovery, code: code)
    }
}

private struct SigningIdentity {
    let certificate: ALTCertificate
    let secret: AccountSecret
}

private struct ProfilePreparation {
    let profiles: [ALTProvisioningProfile]
    let requestedEntitlements: [String: [String: ProvisioningEntitlementValue]]
    let droppedExtensionBundleIdentifiers: [String]
}

private actor SigningSecretState {
    private var secret: AccountSecret

    init(_ secret: AccountSecret) {
        self.secret = secret
    }

    func update(_ secret: AccountSecret) {
        self.secret = secret
    }

    func value() -> AccountSecret {
        secret
    }
}
