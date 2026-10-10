import Foundation

/// 可关联到一次失败、且已移除敏感值的诊断记录。
struct FailureDiagnosticRecord: Equatable, Sendable {
    let diagnosticID: String
    let code: String
    let operation: FailureOperation
    let origin: FailureOrigin
    let redactedCause: String

    init(failure: ImportFailure, underlying: Error) {
        diagnosticID = failure.diagnosticID
        code = failure.code
        operation = failure.operation
        origin = failure.origin
        redactedCause = Self.redactRequestURLs(
            in: LogPrivacyRedactor.redact(ErrorDiagnosticFormatter.diagnostic(for: underlying))
        )
    }

    private static func redactRequestURLs(in value: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"https?://[^\s|]+"#,
            options: [.caseInsensitive]
        ) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: "[redacted-url]"
        )
    }
}
