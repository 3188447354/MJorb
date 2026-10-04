import Foundation

struct ImportFailure: Error, Equatable, Identifiable, Sendable {
    let title: String
    let reason: String
    let recovery: String
    let code: String

    var id: String { code }

    /// 无法由用户自行解决时的统一指引（2026-10-04 死代码审计：11 处硬编码收敛）。
    static let sendLogToAuthor = "把日志发给作者 MJorb"
}

extension ImportFailure: LocalizedError {
    var errorDescription: String? { title }
    var failureReason: String? { reason }
    var recoverySuggestion: String? { recovery }
}

extension ImportFailure {
    var userReason: String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "来源未返回明确原因。" }
        return trimmed
    }

    var userMessage: String {
        userReason
    }
}
