import Foundation

/// 已安装页是尽力读取，不得借用签名/安装后的长验证预算。
enum InstalledAppRefreshProbePolicy {
    /// 正常设备查询为亚秒级；超时后保留本地列表即可，无需让下拉手势转圈 15 秒。
    ///
    /// ⚠️ **保持 2 秒，不要动**（2026-09-26，构建 46 真机复盘）。日志里三次
    /// `SEAL-INSTALL-707`（01:25:01 / 01:26:40 / 01:29:11）确实全部落在续签与自替换
    /// 进行中、2 秒预算必然超时 —— 但根因是**并发**（核验去抢签名链路正在用的设备会话），
    /// **不是预算太短**。把它调大只会让每次失败的等待更长，并让这条「尽力读取」的核验
    /// 悄悄借走安装链路的验证预算。
    /// ⇒ 正确的修法在调用方：`AppsViewModel.reconcileInstalledAppsWithDevice` 在有前台操作时
    /// **整体跳过**（不探测、不报错、不弹窗）。
    static let timeoutSeconds: Double = 2

    /// `BlockingCall` 超时不会停止底层 FFI。冷却期覆盖其默认 15 秒查询预算，避免连续下拉
    /// 不断叠加同一条死会话上的阻塞调用。
    static let timeoutCooldownSeconds: TimeInterval = 20
}
