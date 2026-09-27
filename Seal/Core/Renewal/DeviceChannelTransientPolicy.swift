import Foundation

/// 「设备通道**瞬时**不可用」的判定（纯函数，可单测）。
///
/// ## 为什么单独抽一个类型，而不是在 `RenewalCoordinator` 里直接 `as? MinimuxerError`
///
/// `MinimuxerError` 在 **`SealTests` target 里不可见**（`project.yml` 没给测试 target
/// 声明 Minimuxer 依赖 —— 既有测试也一律不 `import Minimuxer`）。判据若写成
/// `error as? MinimuxerError`，这条行为就**永远测不到**：它只在真机上表现为
/// 「本该重试却没有重试」。所以这里只吃「错误域 + 错误码」两个**可构造**的输入。
///
/// ## 判据为什么是「域 + 序号」而不是文案
///
/// 文案会漂（改一次提示语就失效）。这里用的是 `NSError` 的**结构化**身份：
/// `domain` = 模块限定的类型名 `Minimuxer.MinimuxerError`，`code` = **case 的声明序号**。
/// ⚠️ 序号是「声明顺序」的隐式契约 ⇒ `Vendor/Minimuxer/Sources/MinimuxerError.swift`
/// 里 `NoDevice`（0）/ `NoConnection`（1）**一旦被换序或往前插 case，这里就静默失效**。
/// 守卫 R92 因此钉住「这两个序号与声明顺序一致」，换序会红。
///
/// ## 为什么这两种值得重试
///
/// 它们表达的是**隧道 / 设备会话的瞬时状态**（刚起来、刚被别的东西顶掉），
/// 不是「这条记录有问题」。构建 53 真机实证：后台触发的那一轮两项都以
/// `Minimuxer.MinimuxerError 1`（`NoConnection`）失败，而同一构建、几分钟前的
/// 前台续签 2/2 成功 ⇒ 通道恢复后同样的续签是能成的。
/// **重试的代价只是再跑一次，不重试的代价是整轮白做。**
enum DeviceChannelTransientPolicy {

    /// `Minimuxer` 的错误域。`NSError.domain` 对 Swift 枚举错误就是「模块名.类型名」。
    static let minimuxerErrorDomain = "Minimuxer.MinimuxerError"

    /// 通道瞬时失败的 case 序号 —— **与 `MinimuxerError` 的声明顺序一一对应**：
    /// `NoDevice` = 0（设备还没接上）、`NoConnection` = 1（会话被顶掉 / 隧道未就绪）。
    ///
    /// ⚠️ 刻意**不含** `PairingFile`（= 2）：配对文件坏了是**记录问题**，
    /// 重试一百次也不会好，该让用户重新配对（那是另一条恢复路径）。
    static let transientChannelErrorCodes: Set<Int> = [0, 1]

    static func isTransientChannelFailure(domain: String, code: Int) -> Bool {
        domain == minimuxerErrorDomain && transientChannelErrorCodes.contains(code)
    }

    /// **`ImportFailure` 形态**的通道瞬时失败码 —— 与安装链路的分类同源。
    ///
    /// ## 为什么除了「域 ＋ 序号」还要这一张表
    ///
    /// 安装链路把底层错误**归类成 `ImportFailure` 之后才抛给上层**
    /// （`MinimuxerInstallChannel.start()` / `connectionFailure` / `discoveryFailure`），
    /// 于是续签重试侧拿到的往往是**带码的 `ImportFailure`，而不是裸 `MinimuxerError`**。
    /// 只认「域 ＋ 序号」时这些码会落空 ⇒ 通道抖动又被当成终态错误、整轮白做 ——
    /// 与构建 53 真机那个错法是**同一个**，只是换了一层包装。
    ///
    /// ## 只收「**安装提交之前**」的通道失败
    ///
    /// 判据是「重试**安全**」而不只是「像通道问题」：安装一旦提交（`stageAndInstall`），
    /// 重试就可能在同一 Bundle ID 上造出**并发 installd**（R05 / AGENTS.md「超时 ≠ 失败」）。
    /// 所以：
    ///   · ✅ 收 `start()` / `ensureReady()` / 安装入口 `guard isReady()` 抛出的那些 ——
    ///     都在**没有任何安装被提交**之前，重试只是再跑一次；
    ///   · ✗ 不收 `installationFailure` 归类出来的 `SEAL-INSTALL-702` / `702d`
    ///     （来自安装阶段，底下那次安装可能还在跑）；
    ///   · ✗ 不收 `702t`（超时 ≠ 失败）、`702l` / `702s`（确定性拒绝）、
    ///     `703` / `704` / `707` / `SEAL-PAIR-*`（配对 / 信任是**记录问题**，同 `PairingFile`）、
    ///     `711`–`735`（签名包问题，重试无用）。
    /// ⚠️ 改这张表前先读 `InstallFailureActionPolicy`：两处都在回答「这条码是不是通道类」。
    static let transientChannelFailureCodes: Set<String> = [
        "SEAL-INSTALL-701",   // LocalDevVPN / 本地隧道未就绪
        "SEAL-INSTALL-705",   // 无法连接设备（未能识别具体原因）
        "SEAL-INSTALL-706b",  // 设备连接失败（超时 / 网络不可达 / 无设备）
        "SEAL-INSTALL-706t",  // `start()` 硬超时（**安装尚未提交**，区别于 702t）
        "SEAL-INSTALL-708",   // 设备未响应
        "SEAL-INSTALL-709",   // 与设备的安全握手未完成
        "SEAL-INSTALL-710",   // 本地隧道端口暂时不可达
        "SEAL-VPN-001"        // 签名完成后仍无法连接设备完成安装
    ]

    static func isTransientChannelFailure(_ failure: ImportFailure) -> Bool {
        transientChannelFailureCodes.contains(failure.code)
            || profileOperationTimeoutCodes.contains(failure.code)
    }

    /// 「设备端描述文件操作**卡住**」的码（2026-09-27）。
    ///
    /// 与 `transientChannelFailureCodes` **刻意分开**：那批是「安装提交之前」的通道失败，
    /// 重试前**不需要**动传输；而这两个是「注入 / 回读**超时**」⇒ 底下那次同步 FFI
    /// 没有取消机制、**可能仍在跑**，重试前**必须**先重置设备通道
    /// （`ProfileOnlyProvisioningProfileInstaller` 的污染标记就是干这个的，
    /// 由 `SigningCoordinator.renewProfilesOnly` 消费）。混进上表会让
    /// 「重试前要不要重置传输」这条区别丢失 —— 那正是 R05「超时 ≠ 失败」的落点。
    ///
    /// ⚠️ 这两个码**只**在 `installAndVerify` 里抛出，都在「描述文件注入」这一步：
    /// 注入是幂等的（同一 UUID 覆盖安装）⇒ 重置通道后重试不会造成设备端重复安装。
    static let profileOperationTimeoutCodes: Set<String> = [
        "SEAL-PROFILE-352",   // 注入描述文件超过 30 秒未返回
        "SEAL-PROFILE-353"    // 设备端读回描述文件超过 30 秒未完成
    ]

    /// `Error` 重载：把任意错误归一成上面两条判据之一。
    ///
    /// ⚠️ `ImportFailure` 必须**优先按码判**：它在安装链路里是通道错误的主要形态，
    /// 而 `error as NSError` 对 Swift 结构体错误只会给出 `Seal.ImportFailure` 这种
    /// 非 Minimuxer 域 ⇒ 不先判它，这些码会静默落空（正是构建 53 那个错法的复现）。
    ///
    /// 之所以保留「域 ＋ 码」那条独立入口：单测与守卫都**只**能构造 `NSError(domain:code:)`
    /// （测试 target 看不到 `MinimuxerError`）⇒ 判据必须是可构造输入的纯函数，
    /// 而调用点（`RenewalCoordinator`）拿到的只有 `Error`。
    static func isTransientChannelFailure(_ error: Error) -> Bool {
        if let failure = error as? ImportFailure {
            return isTransientChannelFailure(failure)
        }
        let nsError = error as NSError
        return isTransientChannelFailure(domain: nsError.domain, code: nsError.code)
    }

    /// 重试前的退避基数（秒）：通道类失败**刻意比网络重试更长**。
    ///
    /// 隧道恢复是「秒级到十几秒级」的事，而网络重试用的是 2 秒 × 次数 ——
    /// 那个退避几乎必然撞在通道还没恢复的窗口里，重试等于白跑（构建 53 真机：
    /// 两项失败相隔 30 秒以上，说明 2/4 秒对这种问题太短）。
    static let channelRetryDelayNanoseconds: UInt64 = 8_000_000_000
}
