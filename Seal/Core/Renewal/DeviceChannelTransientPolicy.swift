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

    /// `Error` 重载：把任意错误的 `NSError` 身份（域 ＋ 码）取出来交给上面那条纯判据。
    ///
    /// 之所以保留「域 ＋ 码」那条独立入口：单测与守卫都**只**能构造 `NSError(domain:code:)`
    /// （测试 target 看不到 `MinimuxerError`）⇒ 判据必须是可构造输入的纯函数，
    /// 而调用点（`RenewalCoordinator`）拿到的只有 `Error`。
    static func isTransientChannelFailure(_ error: Error) -> Bool {
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
