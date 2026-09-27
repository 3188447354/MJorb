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
}
