import Foundation

/// 已安装页的设备核验失败必须保留底层原因；仅记录 domain/code 无法判断是查询超时还是设备服务拒绝。
enum InstalledAppRefreshFailure {
    static func diagnostic(for error: Error) -> String {
        let nsError = error as NSError
        let description = LogPrivacyRedactor.redact(nsError.localizedDescription)
        return "设备应用查询未完成 [\(nsError.domain) \(nsError.code)] \(description)"
    }
}
