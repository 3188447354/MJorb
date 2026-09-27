import Foundation

/// 「本地隧道掉线」的判定（纯函数，可单测）。
///
/// ## 为什么与 `DeviceChannelTransientPolicy` 分开
///
/// 那一条回答的是「这次失败**要不要重试**」；这一条回答的是
/// 「这次失败**是不是对端消失**」。两者的处置不同：
/// - 掉线 ⇒ 复用中的**会话必然已死**，重试前必须先把 Swift 侧会话缓存作废，
///   否则下一次 `start()` 会在 900 秒缓存窗口内直接还回那个死会话
///   （这正是 2026-09-27 真机「重试三次都撞同一个死会话」的形态）；
/// - 其它通道抖动 ⇒ 会话可能还活着，只需退避后重试。
///
/// ## 判据来源
///
/// 移植上游 `SideStore/minimuxer` 的 `DeviceGatewayError.isVPNDrop` 思路：
/// `broken pipe` / `connection reset` / `early eof` 这类是**传输层对端消失**，
/// 与「设备拒绝安装（`ApplicationVerificationFailed`）」「记录有问题（配对文件损坏）」
/// 是**不同类别** —— 前者重连可恢复，后者重试多少次都一样。
///
/// ⚠️ 刻意用**子串**而不是精确相等：底层错误文本来自 Rust FFI，前后会带上下文
/// （`Socket error: Broken pipe`、`read: connection reset by peer` …）。
enum DeviceChannelVPNDropPolicy {

    /// 传输层「对端消失」标记（大小写不敏感子串）。
    ///
    /// 只收**连接层**信号：一旦把 `ApplicationVerificationFailed` / `No space left`
    /// 这类设备语义错误收进来，「掉线」就失去区分度、缓存会被无谓作废。
    static let dropMarkers: [String] = [
        "broken pipe",
        "connection reset",
        "reset by peer",
        "econnreset",
        "early eof",
        "connection closed",
        "enotconn",
        "no route to host",
        "network is down",
        "network is unreachable"
    ]

    static func isVPNDrop(detail: String) -> Bool {
        let normalized = detail.lowercased()
        return dropMarkers.contains { normalized.contains($0) }
    }

    /// `Error` 重载：安装链路把底层错误归类成 `ImportFailure` 后抛出，
    /// 原始文本落在 `reason` 里（`errorDescription` 只回 title）⇒ 必须两处都查。
    static func isVPNDrop(_ error: Error) -> Bool {
        if let failure = error as? ImportFailure {
            return isVPNDrop(detail: failure.reason) || isVPNDrop(detail: failure.title)
        }
        // 非 `ImportFailure` 必须走 `MinimuxerInstallChannel.errorDetail`（**取词同源**）：
        // 生产安装路径抛的是 `MinimuxerError.InstallApp(deviceError)`，桥接成 `NSError` 后
        // `localizedDescription` 只剩「The operation couldn't be completed…」，
        // 关联值里的 `Broken pipe` / `connection reset` **全部丢失** ⇒ 掉线判定恒为 false、
        // 死会话不被作废（正是「重试三次都撞同一个死会话」的形态）。
        // `errorDetail` 对 `MinimuxerError` 走 `Minimuxer.describeError` ⇒ `InstallApp(msg)` 保留。
        let nsError = error as NSError
        return isVPNDrop(detail: MinimuxerInstallChannel.errorDetail(error))
            || isVPNDrop(detail: "\(nsError.domain) \(nsError.code)")
    }
}