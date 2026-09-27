import Foundation

/// 把 `Minimuxer` 的「通道不就绪**原因**」映射成 Seal 侧可判读的**类别**（纯函数，可单测）。
///
/// ## 为什么需要它
///
/// 上游 `SideStore/minimuxer` 的就绪判据能区分「配对没加载 / 没启动 / 没有 VPN /
/// 不可达 / 没有设备 / muxer 没监听」；而 Seal 过去只有 `Minimuxer.ready() -> Bool`
/// ⇒ 上层只能给一句「设备连接失败（超时 / 网络不可达 / 无设备）」，
/// 用户分不清「LocalDevVPN 没开」与「设备没响应」—— 那是两种完全不同的下一步动作。
///
/// `Vendor/Minimuxer` 已新增 `MinimuxerReadyVerdict`（`isReady` ＋ `issue`）；
/// 本类型负责把 `issue` 翻成 Seal 侧的分类，`MinimuxerInstallChannel` 再据此给出
/// 精确的失败码与恢复引导。
///
/// ## 为什么吃**字符串**而不是 `MinimuxerReadyIssue`
///
/// `SealTests` target 没有 Minimuxer 依赖（与 `DeviceChannelTransientPolicy` 同一原因）
/// ⇒ 判据若写成枚举，这条行为**永远测不到**（它只在真机上表现为「给错引导」）。
/// 因此 `MinimuxerReadyIssue.rawValue` 被当成**跨模块契约**：改 vendor 的 rawValue
/// 等于改契约，守卫 R94 同时钉住两边的字符串一致。
enum ChannelReadinessPolicy {

    /// 通道不就绪的类别。命名按**用户要做的下一步动作**分，不按上游的字段名分。
    enum Cause: Hashable {
        /// VPN 接口还没出现 ⇒ 还没从 VPN 接口上发现对端（LocalDevVPN 没开 / 刚连上）。
        case vpnNotConnected
        /// VPN 接口在、但设备服务端口不可达 ⇒ 隧道没真正把流量转发到设备。
        case tunnelUnreachable
        /// 配对已加载但通道没起来，或 usbmuxd 未就绪。
        case notStarted
        /// 保活心跳已中断 ⇒ 会话可能已失效（保活让进程跨轮存活，这条最容易被忽略）。
        case heartbeatStale
        /// 隧道通、但设备没有出现在设备列表里。
        case deviceMissing
        /// 认不出的原因（含「探测本身超时」的未知态）。
        case unknown
    }

    /// `MinimuxerReadyIssue.rawValue` → `Cause`。
    ///
    /// ⚠️ 这里出现的每个字符串都必须与
    /// `Vendor/Minimuxer/Sources/Minimuxer.swift` 的 `MinimuxerReadyIssue` 一一对应；
    /// 守卫 R94① 会同时检查两边，改一处不改另一处会红。
    static func cause(fromIssueRawValue raw: String?) -> Cause {
        switch raw {
        case "noVPNInterface":
            return .vpnNotConnected
        case "tunnelUnreachable":
            return .tunnelUnreachable
        case "notStarted", "usbmuxdNotReady":
            return .notStarted
        case "heartbeatStale":
            return .heartbeatStale
        case "noDevice":
            return .deviceMissing
        default:
            return .unknown
        }
    }
}