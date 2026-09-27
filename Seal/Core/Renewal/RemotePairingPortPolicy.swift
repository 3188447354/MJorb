import Foundation

/// RemotePairing 端口自愈的**纯判据**（可单测）。
///
/// ## 为什么需要它
///
/// iOS **不保证**把 `_remotepairing._tcp` 挂在固定端口上，而 Seal 过去把它硬编码成
/// 49152（`MuxerConstants.rsdPort`）⇒ 设备侧该守护进程换端口之后，就变成
/// 「LocalDevVPN 通、隧道也通，但这个端口不通」，而重试只会一轮一轮撞同一个死端口。
/// 上游 SideStore 的补救是：**失败后经 Bonjour 重查端口，变了就换**
///（`MinimuxerWrapper.isRetriableRemotePairingError` → `resolveDiscoveredRemotePairingPortThrottled`
/// → 换端口 → 重试一次）—— 本仓按同一机制对齐。
///
/// ## 判据只认一类失败
///
/// 在 RSD 路径上，`Minimuxer.readyVerdict()` 的就绪探测就是
/// `testDeviceConnection(ifaddr: "10.7.0.1")` 对**当前端口**做一次 TCP 探测
///（`Vendor/Minimuxer/Sources/Minimuxer.swift` 的 `Muxer.isrppairing` 分支）⇒
/// 端口不对必然报 `.tunnelUnreachable` ⇒ 经 `ChannelReadinessPolicy` 归成
/// `SEAL-INSTALL-710`。**只有这一类**值得重查端口：
/// 其它原因（VPN 没接口 / 没启动 / 心跳丢 / 没有设备 / 未知）换端口都无济于事，
/// 设备语义拒绝（空间不足 / 验证失败 / 3 应用上限）更不该触发一次 Bonjour 浏览。
enum RemotePairingPortPolicy {

    /// 要浏览的 Bonjour 服务类型，**按优先级**（对齐上游 `MinimuxerConstants` 的三个常量）。
    /// `_remotepairing._tcp` 是已配对设备上的正常 RSD 服务，后两个是配对流程用的变体。
    static let serviceTypes: [String] = [
        "_remotepairing._tcp",
        "_remotepairing-pairable-host._tcp",
        "_remotepairing-manual-pairing._tcp"
    ]

    /// 触发「重查端口」的失败码 —— **显式集合**，不用数字区间。
    ///
    /// ⚠️ 不许写成 `hasPrefix("SEAL-INSTALL-71")`：那个区间里还有 `709`（安全握手未完成）
    /// 与 `702l`/`702s` 等设备语义拒绝，把它们算成「端口不对」会白跑一轮 Bonjour 浏览
    ///（`AGENTS.md` 第 3 节：错误码 → 动作必须用显式码集合）。
    static let reprobeFailureCodes: Set<String> = [
        "SEAL-INSTALL-710"
    ]

    /// 这一条**就绪失败码**是否值得重查 RemotePairing 端口。
    static func shouldReprobe(failureCode: String?) -> Bool {
        guard let failureCode else { return false }
        return reprobeFailureCodes.contains(failureCode)
    }

    /// 「连不上设备服务端口」的底层错误文本标记（重试循环里拿到的是 raw error，没有码）。
    ///
    /// 取词与 `MinimuxerInstallChannel.classifyDiscoveryFailure` 的隧道类标记同源，
    /// 但**更窄**：只留「连接被拒 / 路由不可达 / 连接超时」这类**端口层**信号，
    /// 不含 `socket`/`network` 这种宽词（那会把「装到一半掉线」也算进来，
    /// 而那是 `DeviceChannelVPNDropPolicy` 的活）。
    static let unreachableMarkers: [String] = [
        "connection refused",
        "refused",
        "no route to host",
        "network is unreachable",
        "unreachable",
        "connection timed out"
    ]

    /// 这一条**底层错误文本**是否值得重查端口。
    static func shouldReprobe(detail: String) -> Bool {
        let lower = detail.lowercased()
        return unreachableMarkers.contains { lower.contains($0) }
    }

    /// 发现到的端口是否应当采纳：与当前**不同**、且非 0。
    ///
    /// 返回 `nil` = 无需改动（没发现到 / 端口相同 / 端口非法）。
    /// 端口没变时**什么都不做** —— 不无谓拆掉一条已经好的 RSD 连接。
    static func resolve(current: UInt16, discovered: UInt16?) -> UInt16? {
        guard let discovered, discovered != 0, discovered != current else { return nil }
        return discovered
    }
}