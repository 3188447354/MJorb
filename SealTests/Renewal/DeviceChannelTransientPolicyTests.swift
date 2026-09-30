import Foundation
import Testing
@testable import Seal

/// 「设备通道瞬时失败」这条判据的自证。
///
/// **为什么值得单测**：它的错法只在真机上表现为「本该重试却没有重试」——
/// 不崩、不编译失败、日志里也只是少了一次重试，事后完全看不出来。
/// 2026-09-26 构建 53 真机：后台触发的那一轮两项都以
/// `Minimuxer.MinimuxerError 1`（`NoConnection`）失败，而同一构建、几分钟前的
/// 前台续签 2/2 成功 —— 这就是「通道抖动被当成终态错误」的实际代价。
///
/// **为什么测的是「域 + 序号」而不是 `MinimuxerError`**：`SealTests` target
/// 没有 Minimuxer 依赖（见 `DeviceChannelTransientPolicy` 的说明）⇒ 只能构造
/// `NSError(domain:code:)`。序号与 `MinimuxerError` 声明顺序的一致性由守卫 R92 钉。
@Suite("设备通道瞬时失败：判据与退避")
struct DeviceChannelTransientPolicyTests {

    @Test("Minimuxer 的 NoDevice(0) / NoConnection(1) 判为瞬时通道失败")
    func deviceAbsentAndConnectionLostAreTransient() {
        let domain = DeviceChannelTransientPolicy.minimuxerErrorDomain
        #expect(DeviceChannelTransientPolicy.isTransientChannelFailure(domain: domain, code: 0))
        #expect(DeviceChannelTransientPolicy.isTransientChannelFailure(domain: domain, code: 1))
    }

    @Test("配对文件坏了（PairingFile = 2）刻意**不**判为可重试")
    func pairingFileIsDeliberatelyNotTransient() {
        // 配对文件是**记录问题**：重试一百次也不会好，该让用户重新配对。
        // 把它误判成瞬时 ⇒ 每轮白等 8/16 秒再失败，用户看到的是「变慢了还不行」。
        let domain = DeviceChannelTransientPolicy.minimuxerErrorDomain
        #expect(DeviceChannelTransientPolicy.isTransientChannelFailure(domain: domain, code: 2) == false)
        #expect(DeviceChannelTransientPolicy.transientChannelErrorCodes == [0, 1])
    }

    @Test("别的错误域一律不算（不能把网络/签名错误吞进通道重试）")
    func otherDomainsAreNeverChannelFailures() {
        #expect(DeviceChannelTransientPolicy.isTransientChannelFailure(
            domain: "NSURLErrorDomain", code: 0) == false)
        #expect(DeviceChannelTransientPolicy.isTransientChannelFailure(
            domain: "Minimuxer.MinimuxerErrorOther", code: 1) == false)
    }

    @Test("Error 重载与「域 + 码」重载结论一致")
    func errorOverloadMatchesDomainAndCodeOverload() {
        let domain = DeviceChannelTransientPolicy.minimuxerErrorDomain
        for code in 0...3 {
            let error = NSError(domain: domain, code: code)
            #expect(
                DeviceChannelTransientPolicy.isTransientChannelFailure(error)
                    == DeviceChannelTransientPolicy.isTransientChannelFailure(domain: domain, code: code)
            )
        }
        // 非 Minimuxer 错误走同一条判定，不得被误收
        #expect(DeviceChannelTransientPolicy.isTransientChannelFailure(
            NSError(domain: "NSCocoaErrorDomain", code: 1)) == false)
    }

    @Test("通道退避必须**长于**网络重试基数（否则重试必然撞在通道还没恢复的窗口里）")
    func channelRetryDelayIsLongerThanNetworkRetryBase() {
        // 网络重试基数是 `RenewalCoordinator.baseRetryDelay` = 2 秒。
        // 这里把「必须更长」写成断言，避免以后有人把它调回 2 秒
        //（构建 53 真机：两项失败相隔 30 秒以上 ⇒ 2/4 秒对通道问题太短）。
        #expect(DeviceChannelTransientPolicy.channelRetryDelayNanoseconds > 2_000_000_000)
        #expect(DeviceChannelTransientPolicy.channelRetryDelayNanoseconds == 8_000_000_000)
    }

    @Test("续签协调器把通道瞬时失败纳入可重试，但不把配对文件问题纳入")
    func renewalCoordinatorTreatsChannelFailuresAsRetryable() {
        let domain = DeviceChannelTransientPolicy.minimuxerErrorDomain
        #expect(RenewalCoordinator.isRetryable(NSError(domain: domain, code: 0)))
        #expect(RenewalCoordinator.isRetryable(NSError(domain: domain, code: 1)))
        #expect(RenewalCoordinator.isRetryable(NSError(domain: domain, code: 2)) == false)
    }

    @Test("安装链路归类出的通道 `ImportFailure` 也算瞬时（否则整轮白做）")
    func channelFamilyImportFailuresAreTransient() {
        // 安装链路把底层错误**归类成带码的 `ImportFailure`** 才抛给续签侧，
        // 所以重试判据必须认这些码 —— 只认「域 ＋ 序号」时它们会落空。
        for code in DeviceChannelTransientPolicy.transientChannelFailureCodes {
            let failure = ImportFailure(title: "", reason: "", recovery: "", code: code)
            #expect(DeviceChannelTransientPolicy.isTransientChannelFailure(failure))
            #expect(RenewalCoordinator.isRetryable(failure))
        }
        // 两条**典型**的「冷启动后台续签」失败码必须可重试：
        // 隧道还没起来（706b）与签名后连不上设备（SEAL-VPN-001）。
        #expect(RenewalCoordinator.isRetryable(
            ImportFailure(title: "", reason: "", recovery: "", code: "SEAL-INSTALL-706b")))
        #expect(RenewalCoordinator.isRetryable(
            ImportFailure(title: "", reason: "", recovery: "", code: "SEAL-VPN-001")))
        // profile 服务已经即时窄重建过一次仍不可用，才交外层最终兜底。
        #expect(RenewalCoordinator.isRetryable(
            ImportFailure(title: "", reason: "", recovery: "", code: "SEAL-PROFILE-356")))
    }

    @Test("安装阶段 / 确定性拒绝 / 配对类码**不得**算瞬时（重试会造并发安装或纯白跑）")
    func installationStageAndTerminalCodesAreNotTransient() {
        let notTransient = [
            "SEAL-INSTALL-702",    // 安装阶段归类（底下那次安装可能还在跑）
            "SEAL-INSTALL-702d",   // 与设备连接断开（安装阶段）
            "SEAL-INSTALL-702t",   // 超时 ≠ 失败（R05 的核心判据）
            "SEAL-INSTALL-702l",   // iOS 拒绝：3 应用上限 / 校验失败
            "SEAL-INSTALL-702s",   // 设备存储空间不足
            "SEAL-INSTALL-703",    // 配对不可用（记录问题）
            "SEAL-INSTALL-704",    // 设备尚未信任（要用户在设备上操作）
            "SEAL-INSTALL-707",    // 无法刷新已安装应用（记录问题）
            "SEAL-INSTALL-711",    // 签名包缺失（重签才行）
            "SEAL-INSTALL-735",    // 需重启 Seal
            "SEAL-INSTALL-738",    // 上一笔自替换安装仍在跑
            "SEAL-PAIR-203b",      // 设备未配对
            "SEAL-PAIR-211"        // 设备未信任当前配对
        ]
        for code in notTransient {
            let failure = ImportFailure(title: "", reason: "", recovery: "", code: code)
            #expect(DeviceChannelTransientPolicy.isTransientChannelFailure(failure) == false)
            #expect(RenewalCoordinator.isRetryable(failure) == false)
        }
    }

    @Test("取消永远不可重试（通道判定不能把它翻过来）")
    func cancellationIsNeverRetryable() {
        #expect(RenewalCoordinator.isRetryable(CancellationError()) == false)
    }

    // ── 单应用续签的重试预算（2026-09-27 真机：自替换后自动续签 Seal 硬失败）──────

    @Test("单应用重试预算与批量一致（同一份策略，不另造一套）")
    func singleAppRetryBudgetMatchesBatch() {
        // `RenewalCoordinator.maxAttempts` = 3。两处必须一致，否则「同一个通道抖动」
        // 在批量能自愈、在单签整轮白做（这正是本次真机踩到的形态）。
        #expect(DeviceChannelTransientPolicy.singleAppMaxAttempts == 3)
    }

    @Test("还有预算且是通道瞬时失败才重试；预算用尽或非通道错误一律不重试")
    func shouldRetryRespectsBudgetAndChannelJudgement() {
        let channelError = NSError(
            domain: DeviceChannelTransientPolicy.minimuxerErrorDomain, code: 1)
        // 预算内 + 通道瞬时 ⇒ 重试
        #expect(DeviceChannelTransientPolicy.shouldRetry(
            afterAttempt: 1, maxAttempts: 3, error: channelError))
        #expect(DeviceChannelTransientPolicy.shouldRetry(
            afterAttempt: 2, maxAttempts: 3, error: channelError))
        // 预算用尽 ⇒ 不重试（最后一次失败必须落到用户可见的错误上）
        #expect(DeviceChannelTransientPolicy.shouldRetry(
            afterAttempt: 3, maxAttempts: 3, error: channelError) == false)
        // 非通道错误 ⇒ 不重试（配对文件坏了、签名包问题重试无用）
        #expect(DeviceChannelTransientPolicy.shouldRetry(
            afterAttempt: 1, maxAttempts: 3,
            error: NSError(domain: DeviceChannelTransientPolicy.minimuxerErrorDomain, code: 2)
        ) == false)
        #expect(DeviceChannelTransientPolicy.shouldRetry(
            afterAttempt: 1, maxAttempts: 3, error: NSError(domain: "NSURLErrorDomain", code: 1)
        ) == false)
    }

    @Test("取消绝不重试（用户点了取消不该被重试拖住）")
    func shouldRetryNeverRetriesCancellation() {
        #expect(DeviceChannelTransientPolicy.shouldRetry(
            afterAttempt: 1, maxAttempts: 3, error: CancellationError()) == false)
    }

    @Test("重试退避随尝试序号增长（8 秒基数 × 第几次）")
    func retryDelayGrowsWithAttempt() {
        #expect(DeviceChannelTransientPolicy.retryDelayNanoseconds(forAttempt: 1)
            == DeviceChannelTransientPolicy.channelRetryDelayNanoseconds)
        #expect(DeviceChannelTransientPolicy.retryDelayNanoseconds(forAttempt: 2)
            == DeviceChannelTransientPolicy.channelRetryDelayNanoseconds * 2)
        // 防御：非法序号（0 / 负数）不得把退避算成 0
        #expect(DeviceChannelTransientPolicy.retryDelayNanoseconds(forAttempt: 0)
            == DeviceChannelTransientPolicy.channelRetryDelayNanoseconds)
    }

    @Test("通道类失败重试前要拆死会话；描述文件超时类交给污染闸门自己拆")
    func requiresChannelResetOnlyForChannelFailures() {
        // 通道类（裸 Minimuxer 错误 / 安装提交前的通道码）⇒ 要 reset
        #expect(DeviceChannelTransientPolicy.requiresChannelResetBeforeRetry(
            NSError(domain: DeviceChannelTransientPolicy.minimuxerErrorDomain, code: 1)))
        #expect(DeviceChannelTransientPolicy.requiresChannelResetBeforeRetry(
            ImportFailure(title: "", reason: "", recovery: "", code: "SEAL-INSTALL-706b")))
        // 描述文件超时类 ⇒ 不重复拆（`renewProfilesOnly` 的 `ProfileOnlyTaintGate` 会自己
        // reset + start；这里再拆一次只是多付一轮诊断）
        #expect(DeviceChannelTransientPolicy.requiresChannelResetBeforeRetry(
            ImportFailure(title: "", reason: "", recovery: "", code: "SEAL-PROFILE-355t")) == false)
        #expect(DeviceChannelTransientPolicy.requiresChannelResetBeforeRetry(
            ImportFailure(title: "", reason: "", recovery: "", code: "SEAL-PROFILE-352")) == false)
        #expect(DeviceChannelTransientPolicy.requiresChannelResetBeforeRetry(
            ImportFailure(title: "", reason: "", recovery: "", code: "SEAL-PROFILE-353")) == false)
        // 非通道错误 ⇒ 不拆
        #expect(DeviceChannelTransientPolicy.requiresChannelResetBeforeRetry(
            ImportFailure(title: "", reason: "", recovery: "", code: "SEAL-INSTALL-702l")) == false)
    }

    @Test("单应用失败归类：通道类给带码可引导的 SEAL-SIGN-504，其余才是 SEAL-SIGN-500")
    func singleAppFailureClassificationRoutesChannelFailures() {
        // 裸 Minimuxer NoConnection（真机里自替换后自动续签 Seal 撞到的那个）⇒ 504 + 跳 VPN 页
        let channelFailure = AppsViewModel.signingFailure(for:
            NSError(domain: DeviceChannelTransientPolicy.minimuxerErrorDomain, code: 1))
        #expect(channelFailure.code == "SEAL-SIGN-504")
        #expect(InstallFailureSettingsRoute.route(forCode: channelFailure.code) == .localDevVPN)
        // 非通道的未预期错误 ⇒ 保持 500，且不误导用户去 VPN 页
        let otherFailure = AppsViewModel.signingFailure(for:
            NSError(domain: "Seal.SomeUnexpected", code: 7))
        #expect(otherFailure.code == "SEAL-SIGN-500")
        #expect(InstallFailureSettingsRoute.route(forCode: otherFailure.code) == nil)
    }
}
