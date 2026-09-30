import Foundation

/// profile-only 设备服务的短时健康租约策略。
///
/// RSD/UDID 可达不代表 misagent 已能立即处理描述文件。这里的租约只决定是否要
/// 再做一次无副作用的服务探测，绝不参与 profile-only 续签资格判断。
enum ProfileServiceLeasePolicy {
    static let leaseDuration: TimeInterval = 20

    static func requiresProbe(lastHealthyAt: Date?, now: Date) -> Bool {
        guard let lastHealthyAt else { return true }
        return now.timeIntervalSince(lastHealthyAt) >= leaseDuration
    }

    static func shouldRebuildAfterProbeFailure(hasRebuilt: Bool) -> Bool {
        hasRebuilt == false
    }
}
