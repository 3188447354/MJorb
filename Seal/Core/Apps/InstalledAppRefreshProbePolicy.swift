import Foundation

/// 已安装页是尽力读取，不得借用签名/安装后的长验证预算。
enum InstalledAppRefreshProbePolicy {
    /// 正常设备查询为亚秒级；超时后保留本地列表即可，无需让下拉手势转圈 15 秒。
    static let timeoutSeconds: Double = 2

    /// `BlockingCall` 超时不会停止底层 FFI。冷却期覆盖其默认 15 秒查询预算，避免连续下拉
    /// 不断叠加同一条死会话上的阻塞调用。
    static let timeoutCooldownSeconds: TimeInterval = 20
}
