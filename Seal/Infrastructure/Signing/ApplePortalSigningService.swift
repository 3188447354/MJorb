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

    /// 创建 App ID 的**顺序**：主 App 必须排在最前。
    ///
    /// ⚠️ 顺序就是安全本身（2026-09-17）。免费账号「7 天内最多注册 10 个 App ID」是**共享**名额，
    /// 而多扩展 App（抖音 = 主 App + 8 扩展）一次签名要连发 9 次 `addAppID`。名额不够时：
    /// **扩展创建失败会被「丢弃降级」继续签名，主 App 创建失败则整个签名抛错**。
    /// 原实现按 Bundle ID 字母序创建 ⇒ 只要有一个扩展的 Bundle ID 排在主 App 之前，
    /// 它就会先把有限名额吃掉，轮到主 App 时名额已空 ⇒ **整个签名失败，而名额已经白花**。
    /// 主 App 优先之后最坏只是「部分扩展被丢弃」（界面本来就会列出被丢弃的扩展），
    /// 而不是「这个 App 签不上」。
    ///
    /// 抽成纯函数是为了能写单测 —— 它的错法只在真机上可见：名额充足时两种顺序结果完全一样。
    static func preparationOrder(
        mappings: [String: String],
        mappedMainBundleID: String
    ) -> [(original: String, mapped: String)] {
        mappings
            .map { (original: $0.key, mapped: $0.value) }
            .sorted { lhs, rhs in
                let lhsIsMain = lhs.mapped == mappedMainBundleID
                let rhsIsMain = rhs.mapped == mappedMainBundleID
                if lhsIsMain != rhsIsMain { return lhsIsMain }
                return lhs.original < rhs.original
            }
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
            // 统一走 isSessionExpiredError，不再用 `diagnostic.contains("1100")` 这类子串匹配 ——
            // 形如 `com.example.app1100` 的 Bundle ID 报错会被误判成会话过期，
            // 把「Bundle ID 不可用」错报成「登录过期」，引导用户去做无用功。
            if ApplePortalSigningService.isSessionExpiredError(error) {
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
        //
        // 但**同一个 1100 在两个阶段的含义不同**，文案不能共用：
        // 走到这里时本次签名刚申请完证书且已成功，说明 session 在 Apple 服务端仍然有效，
        // 所以这通常不是真的登录过期，而是「多扩展 App 连续建号」触发了 Apple 的短时限流
        //（抖音 = 主 App + 8 扩展，需连发 9 次 addAppID）。
        // 若沿用账户阶段那句「去重新验证」，用户会陷入
        //「重新验证 → 再签 → 又被限流 → 再被要求验证」的死循环（用户反馈的
        //「无论怎样在验证 Apple ID 就报错失效」）。因此这里必须先给出「稍后重试」。
        if ApplePortalSigningService.isSessionExpiredError(error) {
            return ImportFailure(
                title: "Apple 暂时拒绝了请求",
                reason: "Apple 在注册 App ID 时返回了「会话已过期」。本次签名的证书申请刚刚成功，说明登录状态其实还在 —— 更常见的原因是该 App 的扩展较多（每个扩展都要单独注册一个 App ID），短时间内连续请求触发了 Apple 的限制。\n\n请先等几分钟再重试；如果多次重试仍然失败，再到「我的」页面重新验证这个 Apple ID。",
                recovery: "等几分钟后重试",
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
            // ⚠️ **不能只说「去重新验证」**（2026-09-17 用户反馈）。
            //
            // 同一个「认证状态无效」有两种完全不同的成因：
            //   ① 登录真的失效了 ⇒ 该重新验证；
            //   ② **短时间内请求过密被 Apple 限流**（多扩展 App 的典型症状：
            //      抖音 = 主 App + 8 扩展，一次签名要连发 9 次 `addAppID`）
            //      ⇒ 登录其实还在，重新验证**没有用**，等几分钟就好。
            //
            // 只给 ① 会把用户推进死循环：「重新验证 → 再签 → 又被限流 → 又被要求验证」——
            // 这正是用户反馈的原话（「无论怎样在验证 Apple ID 就报错失效」）。
            // `appIDFailure` 里早就为同一个 1100 修过这个问题，但**证书阶段漏了**。
            //
            // ⇒ 与 App ID 阶段保持同一套顺序：**先等、再验证**；并给出「换个账号」这条出路
            // （新账号没有被限流的历史，是用户手上最有效的一招）。
            return ImportFailure(
                title: "Apple 拒绝了证书请求",
                reason: "Apple 返回：认证状态无效。\n"
                    + "这个错误有两种常见成因：登录真的失效，或者短时间内请求过密被 Apple 限流"
                    + "（扩展较多的 App 一次签名要连续注册多个 App ID，最容易触发）。\n"
                    + "如果同一个 Apple ID 签其它应用是正常的，那更可能是后者 —— 登录状态其实还在。",
                recovery: "先等几分钟重试；若多次重试仍失败，再到「我的」页面重新验证这个 Apple ID，"
                    + "或改用其它 Apple ID 签名",
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
/// Apple 开发者服务请求节流器。
///
/// **为什么需要它**：Apple 对免费账号（Personal Team）的开发者服务请求有频率限制。
/// 抖音这类「主 App + 8 个扩展」的 IPA 需要在 Phase 1 连续创建 9 个 App ID
///（每个还要 updateFeatures）、Phase 2 再连续申请 9 个描述文件 —— 短时间二十余次
/// 连发请求会触发 Apple 侧掐断会话，返回 1100 "Your session has expired. Please log in."。
///
/// **为什么可以判定是限流而不是真过期**（2026-09-16 用户日志）：每一次 AUTH-107 报错前
/// 1–3 秒都有一条「证书决策」成功日志。证书申请能成功，说明 session 在 Apple 服务端
/// 仍然有效；紧接着 App ID 阶段就报 1100，只可能是请求过密。这也解释了用户反馈的
/// 「无论怎样重新验证 Apple ID 都会报错失效」—— 重新登录拿到新 session，密集请求
/// 再次触发限流，形成死循环。
///
/// **为什么放在 `withAppleTimeout` 里**：它是所有 Apple 请求的唯一入口，
/// 一处覆盖全部调用点，不必逐个包装（也不会漏掉将来新增的调用）。
/// 节流器只在「相邻请求间隔小于下限」时才等待，因此对本来就慢的操作
///（如 `waitForCreatedCertificate` 的 500ms 轮询）零影响。
actor AppleRequestThrottle {
    static let shared = AppleRequestThrottle()

    /// 相邻 Apple 请求的最小间隔。取值依据：把二十余次连发拉长到数秒量级，
    /// 足以避开免费账号的短时频率限制，同时不让正常单 App 签名明显变慢。
    private static let minimumInterval: TimeInterval = 0.4

    private var lastRequestAt: Date?

    func wait() async {
        if let lastRequestAt {
            let elapsed = Date().timeIntervalSince(lastRequestAt)
            let remaining = Self.minimumInterval - elapsed
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
        lastRequestAt = Date()
    }
}

func withAppleTimeout<T: Sendable>(
    _ seconds: UInt64 = 20,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    // 先过全局节流，再发请求：这是所有 Apple 请求的必经之路。
    await AppleRequestThrottle.shared.wait()
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
    private static let profileRequestClockTolerance: TimeInterval = 10 * 60
    private static let minimumFreshProfileLifetime: TimeInterval = 7 * 24 * 3600 - profileRequestClockTolerance
    private let anisetteProvider: any AnisetteProvider
    private let signingWorkspace: SigningWorkspace
    private let accountClient: AppleAccountClient
    private let logStore: SealLogStore?
    // 对齐 AltStore：防止并发签名时重复创建 App Group
    // App Group 操作通过 actor 串行化；批量签名为串行循环，无并发创建风险

    init(
        anisetteProvider: any AnisetteProvider = AnisetteV3Client(),
        signingWorkspace: SigningWorkspace = SigningWorkspace(),
        logStore: SealLogStore? = nil
    ) {
        self.anisetteProvider = anisetteProvider
        self.signingWorkspace = signingWorkspace
        self.accountClient = AppleAccountClient(anisetteProvider: anisetteProvider)
        self.logStore = logStore
    }

    private func diagnostic(_ message: String, level: SealLogEntry.Level = .info) async {
        try? await logStore?.append(category: .signing, level: level, message: message)
    }

    private static func diagnosticDate(_ date: Date?) -> String {
        guard let date else { return "缺失" }
        return ISO8601DateFormatter().string(from: date)
    }

    /// 命中 1100「会话已过期」后的退避间隔。
    ///
    /// 见 `AppleRequestThrottle` 的说明：多扩展 App（抖音 = 主 App + 8 扩展）在 App ID
    /// 阶段密集请求会被 Apple 限流，返回的 1100 是「被掐断」而非「真过期」。
    /// 同一 session 往往仍然可用，退避后重试即可成功；重试耗尽才向上抛。
    ///
    /// 累计额外等待 1.5 + 4 + 8 = 13.5 秒。对「本来就会失败」的调用只增加一次
    /// 十几秒的等待，换来的是不必让用户白跑一趟「重新验证 Apple ID」。
    /// ⚠️ **访问级别是 internal 而非 private**：`ApplePortalCertificateService`（证书轮换 / 清理路径）
    /// 也要用**同一组**间隔 —— 「同一条规则两条链路各抄一份」在本仓已踩过 6 次，
    /// 共用一份常量是防止两边漂移的唯一办法（守卫 R29 钉住这一点）。
    static let sessionRecoveryBackoffNanoseconds: [UInt64] = [
        1_500_000_000,
        4_000_000_000,
        8_000_000_000
    ]

    /// 是否为 Apple 的「会话已过期」错误（错误码 1100）。
    ///
    /// 只认错误码与官方英文文案，**不做** `diagnostic.contains("1100")` 这类宽泛匹配 ——
    /// 那会把恰好含 "1100" 的其他错误（如某些 UUID/数字串）误判成会话问题。
    ///
    /// 访问级别是 internal 而非 private：这条边界直接决定「哪些错误值得退避重试」，
    /// 必须能被单测锁住（`withSessionRecovery` 本身含十几秒退避，不适合单测）。
    static func isSessionExpiredError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == 1100 { return true }
        return nsError.localizedDescription.lowercased().contains("session has expired")
    }

    /// 对单个 Apple 请求做「退避重试」。
    ///
    /// 默认只重试会话过期（1100）这一种错误：Bundle ID 冲突、名额上限等都必须立即抛出，
    /// 否则会把本该快速失败的场景拖成十几秒的假等待。
    ///
    /// ⚠️ **`retriesOnTimeout` 只允许「读操作」置 true**（2026-09-18）。
    ///
    /// 为什么读可以、写绝对不行：
    /// - **读是幂等的**（`fetchAppIDs` / `fetchCertificates`）—— 超时重试最坏只是多花时间，
    ///   不会多出任何副作用。而**限流时 Apple 的响应会变慢**，20 秒超时后直接失败太脆；
    ///   而且超时**不是**会话过期（`isSessionExpiredError` 为假）⇒ 原先完全不重试。
    /// - **写绝不能重试超时**：`addCertificate` 的注释写得很清楚 ——
    ///   「请求超时**不代表失败** —— Apple 可能已经建好证书，只是响应没回来；
    ///   即使建好了也**拿不回来**（私钥随响应返回）⇒ **绝不盲目重试（会多占一个证书名额）**」。
    ///   `updateFeatures` 同理；`fetchProvisioningProfile` 内部还会先 delete，更不许重试。
    ///
    /// ⇒ 「读可重试超时、写不可」是**硬规则**，守卫 R33 同时钉住两侧。
    private func withSessionRecovery<T>(
        _ label: String,
        retriesOnTimeout: Bool = false,
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        let delays: [UInt64] = [0] + Self.sessionRecoveryBackoffNanoseconds
        for (attempt, delay) in delays.enumerated() {
            if delay > 0 {
                try Task.checkCancellation()
                // 措辞按**上一次失败的原因**分：会话类保持原文案（文档与清单引用的就是它），
                // 超时另说 —— 否则「会话疑似被限流」会把超时说成限流，又是一条误导文案。
                let kind = lastError.map {
                    Self.isSessionExpiredError($0) ? "会话疑似被限流" : "请求超时"
                } ?? "请求失败"
                await diagnostic(
                    "Apple \(kind)，退避 \(delay / 1_000_000_000) 秒后重试 \(label)（第 \(attempt) 次重试）"
                )
                try await Task.sleep(nanoseconds: delay)
            }
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let retryable = Self.isSessionExpiredError(error)
                    || (retriesOnTimeout && Self.isTimeoutError(error))
                guard retryable else { throw error }
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw ALTAppleAPIError.unknown()
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
        persistRevokedSigningMaterial: @escaping @Sendable (AccountSecret, [String]) async throws -> Void,
        progress: @escaping @Sendable (SigningStage) async -> Void
    ) async throws -> PortalSigningResult {
        let secretState = SigningSecretState(secret)
        let persistence: @Sendable (AccountSecret, String) async throws -> Void = {
            updatedSecret, serialNumber in
            try await persistSigningMaterial(updatedSecret, serialNumber)
            await secretState.update(updatedSecret)
        }
        let revokedPersistence: @Sendable (AccountSecret, [String]) async throws -> Void = {
            updatedSecret, revokedSerials in
            try await persistRevokedSigningMaterial(updatedSecret, revokedSerials)
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
                persistRevokedSigningMaterial: revokedPersistence,
                progress: progress
            )
        } catch let failure as ImportFailure where failure.code == "SEAL-AUTH-107" {
            // ⚠️ **不能无差别替换文案**（2026-09-18 真机：用户因此陷入死循环）。
            //
            // 这条 catch 的原意是「签名时是 LocalDevVPN 环境，自动重登要访问 Apple 认证服务器、
            // 网络不匹配必败 ⇒ 让用户去「我的」页面重新验证」。但它会把**所有** SEAL-AUTH-107
            // 都换成同一句话 —— 包括 `appIDFailure` 那条**特意按阶段区分过**的
            // 「Apple 暂时拒绝了请求 —— 本次证书申请刚成功，说明登录还在，更可能是限流，
            // 请先等几分钟再重试；仍失败再重新验证、或改用其它 Apple ID」。
            //
            // 覆盖的后果（用户 2026-09-18 实测原话：「重新添加 3188447354 后我去签另一个应用
            // 是签名成功，我卸载后又签抖音 还是失败」）：用户读到「去重新验证」→ 真的去重新加
            // Apple ID → 再签 → 又被限流 → 又被要求验证。**这正是 appIDFailure 那段注释
            // 花了很大力气要避免的死循环，却被这里一句话推回去了。**
            //
            // ⇒ 保留原 failure 的 title / reason / recovery（它们已经按阶段区分好、且可执行），
            // 只**追加**一条「签名过程中无法替你重新登录」的环境说明。
            // 不标记 ID 失效这一意图也保持不变（code 仍是 SEAL-AUTH-107）。
            throw ImportFailure(
                title: failure.title,
                reason: failure.reason
                    + "\n\n另外：签名过程中 Seal 无法替你重新登录这个 Apple ID"
                    + "（此时网络要连着设备），需要重新验证的话请到「我的」页面操作。",
                recovery: failure.recovery,
                code: failure.code
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
                persistRevokedSigningMaterial: revokedPersistence,
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
                    persistRevokedSigningMaterial: revokedPersistence,
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
        persistRevokedSigningMaterial: @escaping @Sendable (AccountSecret, [String]) async throws -> Void,
        progress: @escaping @Sendable (SigningStage) async -> Void
    ) async throws -> PortalSigningResult {
        var stage: ApplePortalSigningStage = .account
        do {
            try Task.checkCancellation()
            await progress(.preparingAccount)
            // ⚠️ **把这段静默括起来**（2026-09-17 真机，构建 105）。
            //
            // 真机日志实测：`证书检查` 之后直接跳到 2 分钟后的失败，**中间一行都没有** ——
            // 而这一步恰好是最可能慢的一步（`anisetteProvider.fetch()` 要本地签名内核生成
            // 设备环境，代码在 `SEAL-AUTH-107t` 的文案里就写明「本地签名内核生成设备环境时
            // 卡住」）。没有这两行，「等了 2 分钟」无法归因到具体步骤。
            //
            // 与安装心跳同一条纪律：**长等待必须留下可判读的时间线**。
            // 成功路径也写（耗时是判断「是不是这步慢」的唯一依据），但不写心跳
            // —— 这一步正常是秒级，不需要周期性打点。
            let anisetteStartedAt = Date()
            await diagnostic("签名：正在准备设备环境（anisette）")
            let anisette = try await anisetteProvider.fetch()
            await diagnostic(
                "签名：设备环境已就绪，耗时 \(Int(Date().timeIntervalSince(anisetteStartedAt))) 秒"
            )
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

            // 大 IPA 峰值磁盘空间：解压 ~1x + ldid 临时文件 ~1x + 输出 IPA ~1x。
            // 空间不足会导致 ldid.cpp(538) 写入失败或 ZIPFoundation DataError，提前给出明确提示。
            //
            // ⚠️ **用「解压后」体积算，不要用「压缩体积 × N」**（2026-09-18）。
            // 那个启发式两头都会错，而它排在所有检查的**最前面** ⇒ 错的那一头会**先拦住用户**：
            // - 抖音（压缩比 ≈1.9×）：780MB × 4 = 3.32GB，实际峰值 ≈3.0GB ⇒ **假警报**
            // - 高压缩比的包：100MB × 4 = 600MB，实际峰值 ≈1.7GB ⇒ **低估**
            // 现在直接问 `SigningWorkspace` 要准确值（它本来就要算这个数，顺带把
            // 条目数 / 路径安全 / 8GB 上限也提前到这里暴露）。
            // 拿不到就**放行** —— `prepare` 里还有一道同样的检查兜底（那里 archive 已打开）。
            if let requiredBytes = try? signingWorkspace.requiredTemporarySpace(
                forIPAAt: originalIPAURL
            ) {
                let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                if let docDir,
                   let freeAttrs = try? FileManager.default.attributesOfFileSystem(forPath: docDir.path),
                   let freeBytes = (freeAttrs[.systemFreeSize] as? NSNumber)?.int64Value,
                   freeBytes > 0,
                   UInt64(freeBytes) < requiredBytes {
                    let freeGB = Double(freeBytes) / 1_000_000_000
                    let requiredGB = Double(requiredBytes) / 1_000_000_000
                    throw Self.failure(
                        title: "存储空间不足",
                        reason: String(
                            format: "签名此 IPA 约需 %.1fGB 临时空间（按解压后体积算），当前剩余 %.1fGB。"
                                + "解压产物、输出包与原包会同时占空间。",
                            requiredGB,
                            freeGB
                        ),
                        recovery: "清理手机存储空间后重试",
                        code: "SEAL-SIGN-405"
                    )
                }
            }

            stage = .packaging
            // ⚠️ **这一步单独占一个进度阶段**（2026-09-18 真机，构建 118）。
            //
            // 它只做本地工作（解压 / 改写 Bundle 结构 / 重签所有二进制 / 重新打包），
            // **完全不碰 Apple**，但抖音（**779.7 MB**）在这一步花了 **112 秒**。
            // 原先它被算进 `.preparingAccount`（文案「正在验证 Apple ID」、进度固定 **16%**）
            // ⇒ 用户盯着「正在验证 Apple ID 16%」等了 2 分钟，判断「Apple ID 验证卡住了」，
            // **于是去重新验证 Apple ID** —— 正是「重新验证 → 又被限流」死循环的入口。
            // 同一次日志里 3105（4.3 MB）与 LiveContainer（4.9 MB）是秒级
            // ⇒「只有抖音卡」的真正原因是**包大**，不是账号、不是限流。
            //
            // 顺带把耗时写进日志：「等了多久、花在哪一步」从此可归因（原来这段一行都没有）。
            await progress(.preparingBundle)
            let prepareStartedAt = Date()
            let prepared = try signingWorkspace.prepare(
                ipaURL: originalIPAURL,
                workspaceRoot: workspaceRoot,
                originalBundleID: app.originalBundleIdentifier,
                teamID: team.identifier,
                targetMainBundleID: targetBundleIdentifier,
                preferredDisplayName: app.preferredDisplayName,
                preferredIconData: preferredIconData
            )
            await diagnostic(
                "签名：应用文件准备完成（解压/改写/重签/打包），耗时 \(Int(Date().timeIntervalSince(prepareStartedAt))) 秒"
            )
            try Task.checkCancellation()

            // 证书轮换可能立刻让旧 profile 失效。磁盘容量、IPA 解包、Bundle 结构和
            // 本地重写必须全部先成功，确认已经具备可签产物后才允许触碰 Apple 证书。
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
                persistSigningMaterial: persistSigningMaterial,
                persistRevokedSigningMaterial: persistRevokedSigningMaterial
            )
            try Task.checkCancellation()

            await progress(.preparingAppID)
            stage = .appID
            let profileRequestStartedAt = Date()
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
                requestedEntitlements: profilePreparation.requestedEntitlements,
                requestedAfter: profileRequestStartedAt.addingTimeInterval(-Self.profileRequestClockTolerance)
            )
            guard let mainBinding = profileBindings[prepared.mappedMainBundleID] else {
                throw Self.failure(
                    title: "描述文件校验失败",
                    reason: "签名完成后未找到主应用的 embedded.mobileprovision：\(prepared.mappedMainBundleID)。",
                    recovery: "重新获取描述文件",
                    code: "SEAL-PROFILE-317a"
                )
            }
            for binding in profileBindings.values.sorted(by: { $0.bundleIdentifier < $1.bundleIdentifier }) {
                let serials = binding.certificateSerialNumbers.map {
                    "…" + SigningCertificateSelectionPolicy.normalizedSerialNumber($0).suffix(8)
                }.joined(separator: "、")
                await diagnostic(
                    "描述文件核验：Bundle=\(binding.bundleIdentifier)，UUID=\(binding.profileUUID ?? "缺失")，创建=\(Self.diagnosticDate(binding.creationDate))，到期=\(Self.diagnosticDate(binding.expirationDate))，证书=\(serials)，本轮新申请=是"
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
        persistSigningMaterial: @escaping @Sendable (AccountSecret, String) async throws -> Void,
        persistRevokedSigningMaterial: @escaping @Sendable (AccountSecret, [String]) async throws -> Void
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
            // ⚠️ **不能再 `try?` 吞掉错误**（2026-09-18 真机）。
            // 原先这里写 `if let certificates = try? await fetchCertificates(...)`，错误被丢掉，
            // 于是日志只说「Apple 证书列表暂不可用」，**分不出是限流（1100）、超时还是网络**。
            // 而真机上这段静默可以长达 **112 秒**（抖音两次尝试都是：06:48:46→06:50:38、
            // 06:54:37→06:56:29，中间一行日志都没有）—— 没有任何线索可查。
            // ⇒ 记下**原因 + 耗时**，「暂不可用」才有判读价值。
            let fetchStartedAt = Date()
            var fetchedCertificates: [ALTX509Certificate]?
            var certificateFetchFailure: Error?
            do {
                fetchedCertificates = try await fetchCertificates(team: team, session: session)
            } catch {
                certificateFetchFailure = error
            }
            if let certificates = fetchedCertificates {
                // 在生效列表且剩余有效期覆盖 7 天 profile 寿命才可复用：只查列表/只看当下未过期，
                // 会把「明天就到期的证书」签进新包，次日被 iOS 判「尚未验证」闪退。
                if certificates.contains(where: {
                    SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber) == SigningCertificateSelectionPolicy.normalizedSerialNumber(serial)
                }), Self.certificateReusable(local) {
                    await diagnostic("证书决策：复用 Apple 生效列表中的本机证书 …\(SigningCertificateSelectionPolicy.normalizedSerialNumber(serial).suffix(8))，剩余有效期已通过完整 7 天校验")
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
                // ⚠️ 把失败原因与耗时写进日志（见上）：原先只有一句「暂不可用」，查不出是什么。
                let fetchSeconds = Int(Date().timeIntervalSince(fetchStartedAt))
                var fetchReason = "原因未知"
                if let failure = certificateFetchFailure {
                    let ns = failure as NSError
                    let kind = Self.isSessionExpiredError(failure) ? "疑似限流（1100 会话过期）" : "非会话类错误"
                    fetchReason = "\(kind)；[\(ns.domain) \(ns.code)] \(ns.localizedDescription)"
                }
                await diagnostic("证书列表拉取失败：耗时 \(fetchSeconds) 秒；\(fetchReason)")
                // 网络失败/限流：退回本地证书，保留提速效果。
                // 但免费账号证书可能已过期或临近到期；复用会让 iOS 判定"尚未验证"导致闪退，
                // 因此剩余寿命不足 7 天时必须落入慢速路径重新申请，不得复用。
                if Self.certificateReusable(local) {
                    await diagnostic("证书决策：Apple 证书列表暂不可用，复用本机证书 …\(SigningCertificateSelectionPolicy.normalizedSerialNumber(serial).suffix(8))；本地有效期已通过完整 7 天校验")
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

        // 慢速路径：本地证书不可用，从 Apple 服务器获取证书列表。
        // ⚠️ **读操作 ⇒ 允许重试超时**（限流时 Apple 响应会变慢，20 秒超时后直接失败太脆；
        // 而超时不属于「会话过期」，原先完全不重试）。
        let certificates = try await withSessionRecovery("读取证书列表", retriesOnTimeout: true) {
            try await fetchCertificates(team: team, session: session)
        }
        try Task.checkCancellation()

        var reuseStatusBySerial: [String: SigningCertificateReuseStatus] = [:]
        for remote in certificates {
            guard let local = SigningCertificateMaterialPolicy.availableCertificate(
                secret: secret,
                serialNumber: remote.serialNumber
            ) else { continue }
            reuseStatusBySerial[remote.serialNumber] = SigningCertificateMaterialPolicy.reuseStatus(local)
        }
        let reusableCount = reuseStatusBySerial.values.filter { $0 == .reusable }.count
        let insufficientCount = reuseStatusBySerial.values.filter { $0 == .insufficientLifetime }.count
        let invalidCount = reuseStatusBySerial.values.filter { $0 == .invalidValidity }.count
        await diagnostic(
            "证书决策：远端 \(certificates.count) 张，可复用 \(reusableCount) 张，剩余不足 7 天 \(insufficientCount) 张，日期无效 \(invalidCount) 张，无本机私钥 \(certificates.count - reuseStatusBySerial.count) 张"
        )

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

        // 运行包证书只用于安排轮换顺序：当前 Seal 的证书最后撤销，尽量缩短失效窗口。
        // 只认真实 CMS 签名者：描述文件授权列表可能包含并未实际签名的证书（Task 10）。
        let runningIdentity = await MainActor.run {
            isSeal ? SelfAppMetadata.current()?.installedIdentity : nil
        }
        let sealActualSignerSerials: Set<String>
        let sealSignerConfirmed: Bool
        if let runningIdentity, runningIdentity.isComplete,
           let signer = runningIdentity.mainTarget?.signerSerialNumber {
            sealActualSignerSerials = [signer]
            sealSignerConfirmed = true
        } else {
            sealActualSignerSerials = []
            if isSeal {
                let summary = runningIdentity?.readFailureSummary ?? "installedIdentity 读取失败"
                await diagnostic("证书轮换前身份诊断：\(summary)", level: .warning)
            }
            // 只有签名/续签 Seal 本身才要求先确认运行中签名者；普通 App 不涉及 Seal 身份，
            // 不能因为读不到 Seal 的真实证书就禁止普通 App 的证书轮换。
            sealSignerConfirmed = isSeal == false
        }

        // AltStore/SideStore 的免费团队真实链路：门户已有证书但没有任何可签满 7 天的
        // 本机身份时，先撤销旧证书，再创建新证书。免费团队只有一个活动开发证书槽位，
        // 继续 add 只会确定性得到 3022/7460。
        if team.type == .free, certificates.isEmpty == false {
            let candidates = SigningCertificateMaterialPolicy.rotationCandidates(
                remoteSerialNumbers: certificates.map(\.serialNumber),
                reuseStatusBySerial: reuseStatusBySerial,
                runningSealSerialNumbers: sealActualSignerSerials
            )
            if candidates.isEmpty == false {
                return try await rotateCertificatesAndCreateIdentity(
                    candidates: candidates,
                    sealSignerConfirmed: sealSignerConfirmed,
                    certificates: certificates,
                    secret: secret,
                    team: team,
                    session: session,
                    deviceName: deviceName,
                    persistSigningMaterial: persistSigningMaterial,
                    persistRevokedSigningMaterial: persistRevokedSigningMaterial
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
        } catch let failure as ImportFailure where failure.code == "SEAL-CERT-204b" {
            // 付费团队或 Apple 侧规则变化时，以明确 3022 为触发点执行同一轮换链路。
            let candidates = SigningCertificateMaterialPolicy.rotationCandidates(
                remoteSerialNumbers: certificates.map(\.serialNumber),
                reuseStatusBySerial: reuseStatusBySerial,
                runningSealSerialNumbers: sealActualSignerSerials
            )
            guard candidates.isEmpty == false else { throw failure }
            return try await rotateCertificatesAndCreateIdentity(
                candidates: candidates,
                sealSignerConfirmed: sealSignerConfirmed,
                certificates: certificates,
                secret: secret,
                team: team,
                session: session,
                deviceName: deviceName,
                persistSigningMaterial: persistSigningMaterial,
                persistRevokedSigningMaterial: persistRevokedSigningMaterial
            )
        }
    }

    private func rotateCertificatesAndCreateIdentity(
        candidates: [SigningCertificateRotationCandidate],
        sealSignerConfirmed: Bool,
        certificates: [ALTX509Certificate],
        secret: AccountSecret,
        team: ALTTeam,
        session: ALTAppleAPISession,
        deviceName: String,
        persistSigningMaterial: @escaping @Sendable (AccountSecret, String) async throws -> Void,
        persistRevokedSigningMaterial: @escaping @Sendable (AccountSecret, [String]) async throws -> Void
    ) async throws -> SigningIdentity {
        // 规格硬规则：无法确认当前 Seal 真实签名证书 A 时，禁止自动撤销任何证书。
        // 「无本机私钥」的候选很可能就是运行中 Seal 的命根子证书（第三方工具签发的
        // 非标准结构读不出真实 signer），盲撤会让 Seal 重启后打不开。
        guard sealSignerConfirmed else {
            throw Self.certificateRotationBlockedForUnknownSealSigner()
        }
        await diagnostic("证书轮换：最多检查 \(candidates.count) 张不可用于完整 7 天签名的证书；逐张释放并立即尝试创建，当前 Seal 在用证书排在最后")
        var updatedSecret = secret
        var revokedSerials: [String] = []
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            guard let certificate = certificates.first(where: {
                SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber)
                    == SigningCertificateSelectionPolicy.normalizedSerialNumber(candidate.serialNumber)
            }) else { continue }
            let serial = SigningCertificateSelectionPolicy.normalizedSerialNumber(candidate.serialNumber)
            await diagnostic("证书轮换：撤销 …\(serial.suffix(8))，原因=\(rotationReasonText(candidate.reason))，运行中Seal=\(candidate.isRunningSealCertificate ? "是" : "否")")
            try await revokeCertificate(certificate, team: team, session: session)
            updatedSecret.removeStoredCertificateMaterial(serialNumber: candidate.serialNumber)
            revokedSerials.append(candidate.serialNumber)
            // 每撤销一张立刻持久化，避免进程在多张证书之间被系统终止后仍把已撤销
            // P12 当成有效材料；随后马上尝试创建，成功即停止继续撤销。
            try await persistRevokedSigningMaterial(updatedSecret, [candidate.serialNumber])
            await diagnostic("证书轮换：已撤销并持久化 \(revokedSerials.count) 张，立即创建本机证书")
            do {
                let identity = try await createSigningIdentity(
                    secret: updatedSecret,
                    team: team,
                    session: session,
                    deviceName: deviceName,
                    persistSigningMaterial: persistSigningMaterial
                )
                let newSerial = SigningCertificateSelectionPolicy.normalizedSerialNumber(identity.certificate.serialNumber)
                await diagnostic("证书轮换：新证书已创建并保存，序列号末尾 …\(newSerial.suffix(8))")
                return identity
            } catch let failure as ImportFailure where failure.code == "SEAL-CERT-204b"
                && index + 1 < candidates.count {
                await diagnostic("证书轮换：释放一张后 Apple 仍返回 3022，继续处理下一张不可用证书", level: .warning)
            }
        }
        // ⚠️ 这条文案必须说清**后果**（2026-09-17）。
        //
        // 循环里是「先撤销、再创建」，而创建只在「3022 + 还有下一张」时才继续 ——
        // **其它错误直接抛出，而证书已经撤销了**。所以走到这里时，
        // **用那些证书签名的 App 已经无法启动**（这是本轮真机实测到的真实状态：
        // 某个账号 `证书检查：远端 0 张`，就是上一轮这么留下的）。
        //
        // 旧文案只说「已释放 N 张」+「稍后重试」，两个缺口：
        // ① 用户不会知道「为什么我的 App 突然打不开了」；
        // ② 若失败原因是会话失效（`SEAL-AUTH-102c` 那条路径），「稍后重试」是**无效建议** ——
        //    必须先重新验证账号。
        throw Self.failure(
            title: "证书轮换失败",
            reason: "已释放 \(revokedSerials.count) 张不可用证书，但 Apple 仍未允许创建新的本机签名身份。\n"
                + "用这些证书签名的 App 现在无法启动 —— 需要先让这个 Apple ID 恢复可用，"
                + "再把那些 App 重新签一次才能恢复。",
            recovery: "先确认这个 Apple ID 的登录仍然有效（必要时到「我的」重新验证），再重试",
            code: "SEAL-CERT-227"
        )
    }

    private func rotationReasonText(_ reason: SigningCertificateRotationReason) -> String {
        switch reason {
        case .missingPrivateKey: return "无本机私钥"
        case .insufficientLifetime: return "剩余不足7天"
        case .invalidValidity: return "证书日期无效"
        }
    }

    static func certificateRotationBlockedForUnknownSealSigner() -> ImportFailure {
        Self.failure(
            title: "无法确认当前 Seal 的签名证书",
            reason: "读不出当前 Seal 由哪张证书签名，为避免撤销后 Seal 打不开，已停止本次证书轮换。",
            recovery: "先用电脑的原签名工具覆盖安装一次 Seal，再回来续签",
            code: "SEAL-CERT-232"
        )
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
            // ⚠️ **证书创建也必须过 `withSessionRecovery`**（2026-09-17 补）。
            //
            // 另外两个 portal 变更（创建 App ID、申请描述文件）早就有它，**只有证书创建漏了** ——
            // 而同一条「遇 1100 退避重试」的规则漏在一条链路上，正是本仓反复踩的坑。
            //
            // 为什么这条最要紧：**证书是整条签名流程里第一个真正落到 Apple 侧的变更**，
            // 多扩展 App（抖音 = 主 App + 8 扩展）的上一次尝试刚连发过一批请求，
            // 这次一上来就可能撞上短时限流 ⇒ 返回 1100 ⇒ 被 `certificateFailure` 归类成
            // 「账号需要重新验证」⇒ 用户去重新验证、再签、又被限流（用户 2026-09-17 反馈的死循环）。
            //
            // 退避重试后仍失败才向上抛。顺带：`withSessionRecovery` 每次重试都会写
            // 「Apple 会话疑似被限流，退避 N 秒后重试 创建证书」—— 这条日志本身就是
            // 「到底是不是限流」的直接证据（此前证书阶段完全看不到这一层）。
            let created = try await withSessionRecovery("创建证书") {
                try await addCertificate(
                    team: team,
                    session: session,
                    deviceName: deviceName
                )
            }
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
            guard Self.certificateReusable(fullCert) else {
                throw Self.failure(
                    title: "新证书有效期不足",
                    reason: "Apple 刚创建的证书无法覆盖一份完整 7 天描述文件，Seal 已停止使用该证书。",
                    recovery: "确认手机日期时间为自动设置后重试",
                    code: "SEAL-CERT-229"
                )
            }
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
            let validity = certificate.data.flatMap(X509CertificateValidityReader.validity(from:))
            await diagnostic(
                "新证书核验：序列号末尾 …\(SigningCertificateSelectionPolicy.normalizedSerialNumber(certificate.serialNumber).suffix(8))，生效=\(Self.diagnosticDate(validity?.notBefore))，到期=\(Self.diagnosticDate(validity?.notAfter))，本机P12=已保存"
            )
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
        progress: @escaping @Sendable (SigningStage) async -> Void
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

        // ⚠️ **Phase 1 的入口也要先留痕**（2026-09-18 真机）。
        // 下面那条完整的「名额」诊断要读 `existing`（账号已有列表），所以必须排在 `fetchAppIDs`
        // 之后 —— 而 `fetchAppIDs` 是 Phase 1 的**第一个**请求，它一旦被限流（1100），整轮直接抛出、
        // **那条诊断永远不会写**。真机后果：抖音两次尝试的日志里都**没有**名额诊断，
        // 反而看不出「它根本没走到建号这一步」。
        // ⇒ 先用一条不依赖 `existing` 的日志把入口钉住（只需要 N，不需要发请求）。
        let extensionAppIDCount = mappings.values.filter { $0 != mappedMainBundleID }.count
        await diagnostic(
            "App ID 阶段开始：本次需 \(mappings.count) 个 App ID（主 App 1 + 扩展 \(extensionAppIDCount)），准备读取账号已有列表"
        )
        // ⚠️ **读列表也必须过退避重试**：它是 Phase 1 的第一个请求，撞上短时限流（1100）时
        // 原先会**直接让整轮签名失败**（而不是像 addAppID / 描述文件那样先退避再试），
        // 而且失败点排在名额诊断之前 ⇒ 日志里连「它走到哪一步」都看不出来。
        var existing = try await withSessionRecovery("读取 App ID 列表", retriesOnTimeout: true) {
            try await fetchAppIDs(team: team, session: session)
        }

        // 无条件写一条「App ID 名额」诊断（2026-09-17）。用户报「只有抖音签不上、重新加 ID 也不行」时，
        // 这条日志用来**排除假设**：`需新注册 K` 为 0 ⇒ 本次一个 App ID 都不用新建
        // ⇒ 不可能是「建号突发被限流」。
        // ⚠️ **不能用「账号存活 App ID 数」去算剩余名额** —— 上限是「7 天内注册数的滑动窗口」，
        // 不是「存活数 ≤ 10」。判据是失败时的**日志码**：SEAL-APPID-304 = 名额满 / SEAL-AUTH-107 = 限流。
        let reusableAppIDCount = mappings.values.filter { mapped in
            existing.contains {
                ApplePortalAppIDResolver.matches(
                    existingBundleIdentifier: $0.bundleIdentifier,
                    requestedBundleIdentifier: mapped
                )
            }
        }.count
        await diagnostic(
            "App ID 名额：本次需 \(mappings.count) 个（主 App 1 + 扩展 \(extensionAppIDCount)），"
                + "账号上已有 \(existing.count) 个、其中可复用 \(reusableAppIDCount) 个，"
                + "需新注册 \(mappings.count - reusableAppIDCount) 个"
        )
        // ⚠️ **取证：`fetchAppIDs` 到底会不会回填 `features`**（2026-09-18）。
        //
        // 为什么值得单独埋一条：一次抖音签名要发 32–41 次 Apple 请求，其中**一半**是 Phase 1 的
        // `updateFeatures`（每个 bundle ID 一次）。如果 App ID 已存在、且远端 features 与本次
        // 要设置的一致，这次请求就是**冗余**的 —— 而**减少请求量**正是「扩展多的 App 签不上」
        // （Apple 限流）最直接的解法。
        //
        // 但**绝不能盲改**：`ALTAppID.features` 在本仓代码里**只被写入、从未被读取**，
        // 无法证明 `fetchAppIDs` 会把它填上。若它恒为空，靠它跳过会**静默丢掉 entitlements**
        // （比现状更糟）⇒ 先取证，拿到真机日志确认后再决定要不要做这个优化。
        // 这条诊断要**直接回答「能省多少次请求」**，而不只是「features 是不是空的」——
        // 因为「跳过冗余 updateFeatures」正是砍掉一半 Apple 请求的关键，而它的前置条件
        // 是「远端 features 与本次要设置的**完全一致**」（不一致时跳过会静默丢能力）。
        func desiredFeatureKeys(original: String) -> Set<String> {
            guard let application = applications[original] else { return [] }
            return Set(
                filteredAppIDEntitlements(from: application, team: team)
                    .keys
                    .compactMap { ALTFeature(entitlement: $0) }
                    .map { String(describing: $0) }
            )
        }
        var desiredKeysByMapped: [String: Set<String>] = [:]
        for (original, mapped) in mappings {
            desiredKeysByMapped[mapped] = desiredFeatureKeys(original: original)
        }
        var observedWithFeatures = 0
        var skipCandidates = 0
        var firstMismatch: String?
        for (_, mapped) in mappings {
            guard let matched = existing.first(where: {
                ApplePortalAppIDResolver.matches(
                    existingBundleIdentifier: $0.bundleIdentifier,
                    requestedBundleIdentifier: mapped
                )
            }) else { continue }
            let remoteKeys = Set(matched.features.keys.map { String(describing: $0) })
            guard remoteKeys.isEmpty == false else { continue }
            observedWithFeatures += 1
            let desired = desiredKeysByMapped[mapped] ?? []
            if remoteKeys == desired {
                skipCandidates += 1
            } else if firstMismatch == nil {
                firstMismatch = "\(mapped)：远端 \(remoteKeys.sorted()) vs 本次 \(desired.sorted())"
            }
        }
        await diagnostic(
            "App ID features 诊断：账号已有 \(existing.count) 个 App ID，"
                + "其中 \(observedWithFeatures) 个带回非空 features；"
                + "与本次要设置**完全一致**的有 \(skipCandidates) 个"
                + "（一致的那些理论上可跳过 updateFeatures ⇒ 能省 \(skipCandidates) 次请求）"
                + (firstMismatch.map { "；首个不一致样例 \($0)" } ?? "")
        )

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
        // 顺序：**主 App 优先**（见 `ApplePortalAppIDResolver.preparationOrder`）——
        // 名额不足时让扩展去「丢弃降级」，而不是让主 App 拿不到名额、整个签名失败。
        for (originalBundleID, mappedBundleID) in ApplePortalAppIDResolver.preparationOrder(
            mappings: mappings,
            mappedMainBundleID: mappedMainBundleID
        ) {
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
                        // 多扩展 App（如抖音）在 App ID 阶段密集建号，Apple 会掐断会话返回 1100。
                        // 退避重试后仍失败才向上抛，避免把限流误报成「登录过期」让用户白跑一趟重新验证。
                        let createdBox: LegacyBox<ALTAppID> =
                            try await withSessionRecovery("创建 App ID \(mappedBundleID)") {
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
                        // ⚠️ **`updateFeatures` 也必须过退避重试**（2026-09-17 补）。
                        //
                        // 它是 Phase 1 里每个 bundle ID 的**第二次**门户写入（第一次是 addAppID），
                        // 所以抖音这种 9 扩展 App 一次签名要连发 **9 次** —— 与 addAppID 同等密集，
                        // 却一直没有退避重试。漏掉它有两种后果，而且**都不报错**：
                        // ① 主 App 的 updateFeatures 撞上 1100 ⇒ 落到下面那句
                        //    `guard mappedBundleID != mappedMainBundleID else { throw error }`
                        //    ⇒ **整个签名失败**，用户看到的只是「Apple ID 失效」；
                        // ② 扩展的 updateFeatures 撞上 1100 ⇒ 走降级分支把 entitlements **清空**继续签
                        //    ⇒ 签名「成功」，但扩展在真机上缺权限（静默降级比失败更难查）。
                        // 退避重试把这两种「把限流当成事实」的结局变回「等一会儿就好了」。
                        let updatedAppID: ALTAppID =
                            try await withSessionRecovery("更新应用能力 \(mappedBundleID)") {
                                try await updateFeatures(
                                    appID: appID,
                                    application: application,
                                    team: team,
                                    session: session
                                )
                            }
                        appID = updatedAppID
                        if team.type != .free {
                            // 同上：App Group 的分配也是 per-bundle-ID 的门户写入（付费账号才走）。
                            // 免费账号走不到这里，所以它不是「只有抖音签不上」的成因，
                            // 但同一条「遇 1100 就退避」的规则不该只落在免费路径上。
                            try await withSessionRecovery("分配 App Group \(mappedBundleID)") {
                                try await assignAppGroups(
                                    appID: appID,
                                    application: application,
                                    team: team,
                                    session: session
                                )
                            }
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
                    // 限额是全局的，「移除扩展」也救不了，应透传准确原因，
                    // 而不是包成误导性的「移除扩展后重试」。
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
                // 同上：9 个 bundle ID 连续申请描述文件同样会触发限流。
                let profile = try await withSessionRecovery("申请描述文件 \(preparedAppID.mapped)") {
                    try await fetchProvisioningProfile(
                        for: preparedAppID.appID,
                        team: team,
                        session: session
                    )
                }
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
        let requestStartedAt = Date()
        let requestedAfter = requestStartedAt.addingTimeInterval(-Self.profileRequestClockTolerance)
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

        let candidate: ALTProvisioningProfile
        if deleteSucceeded == false {
            // 免费账号无法删除描述文件（2023-03-20 起 Apple 限制），
            // AltStore 上游确认每次 fetch 已经重新生成，直接校验第一次结果；若 Apple
            // 实际返回旧日期，下面的 freshness 检查会在同一 session 再 fetch 一次。
            candidate = profile
        } else {
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
            candidate = secondBox.value
        }

        do {
            try validateFreshProfile(candidate, requestedAfter: requestedAfter)
            return candidate
        } catch let failure as ImportFailure where [
            "SEAL-PROFILE-315", "SEAL-PROFILE-315a", "SEAL-PROFILE-316"
        ].contains(failure.code) {
            await diagnostic("描述文件首次结果不是本轮完整 7 天文件，立即在同一 Apple 会话重新申请一次", level: .warning)
            let retryBox: LegacyBox<ALTProvisioningProfile> = try await withAppleTimeout(30) {
                try await withCheckedThrowingContinuation { continuation in
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
            try validateFreshProfile(retryBox.value, requestedAfter: requestedAfter)
            return retryBox.value
        }
    }

    private func validateFreshProfile(
        _ profile: ALTProvisioningProfile,
        requestedAfter: Date
    ) throws {
        let binding = try ProvisioningProfileReader().binding(from: profile.data)
        try binding.validateFreshness(
            requestedAfter: requestedAfter,
            minimumRemainingLifetime: Self.minimumFreshProfileLifetime
        )
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
        requestedEntitlements: [String: [String: ProvisioningEntitlementValue]],
        requestedAfter: Date
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
                    expectedDeviceIdentifier: deviceIdentifier,
                    requestedAfter: requestedAfter,
                    minimumRemainingLifetime: Self.minimumFreshProfileLifetime
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
