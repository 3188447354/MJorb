import Foundation

/// 通知调度失败的单一诊断格式。后台重排与设置页必须使用同一份文本，
/// 否则导出的日志无法对应用户看到的失败原因。
enum NotificationSchedulingFailure {
    static func diagnostic(for error: Error) -> String {
        let nsError = error as NSError
        let description = LogPrivacyRedactor.redact(nsError.localizedDescription)
        return "通知调度失败 [\(nsError.domain) \(nsError.code)] \(description)"
    }
}
