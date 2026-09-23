import Foundation

enum PairingValidationStartPolicy {
    /// 导入仅确认文件可读；只有设备通道可达时才开始真实配对验证。
    static func shouldStartAutomatically(tunnelReachable: Bool) -> Bool {
        tunnelReachable
    }
}
