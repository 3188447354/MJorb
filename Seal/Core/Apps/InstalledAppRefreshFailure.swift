import Foundation

/// 已安装页的设备核验失败必须保留底层原因；仅记录 domain/code 无法判断是查询超时还是设备服务拒绝。
enum InstalledAppRefreshFailure {
    /// 冷却与页面任务取消是保护无取消 FFI 的预期结果；首次超时仍需留下诊断。
    static func shouldLogDiagnostic(for error: Error) -> Bool {
        if error is CancellationError {
            return false
        }

        let nsError = error as NSError
        return nsError.domain != "SealInstalledAppDeviceVerifier" ||
            (nsError.code != 3 && nsError.code != 4)
    }

    static func diagnostic(for error: Error) -> String {
        let nsError = error as NSError
        let description = LogPrivacyRedactor.redact(nsError.localizedDescription)
        return "设备应用查询未完成 [\(nsError.domain) \(nsError.code)] \(description)"
    }
}
