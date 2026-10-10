import Foundation

struct ImportFailure: Error, Equatable, Identifiable, Sendable {
    let title: String
    let reason: String
    let recovery: String
    let code: String
    let condition: FailureCondition
    let action: FailureAction
    let route: FailureRoute?
    let retryDisposition: FailureRetryDisposition
    let operation: FailureOperation
    let origin: FailureOrigin
    let diagnosticID: String

    /// 每次失败的关联 ID。不能再只用错误码作为 SwiftUI 身份，否则同码的新失败会被旧弹层吞掉。
    var id: String { diagnosticID }

    init(
        title: String,
        reason: String,
        recovery: String,
        code: String,
        condition: FailureCondition = .unexpected,
        action: FailureAction = .copyDiagnostics,
        route: FailureRoute? = nil,
        retryDisposition: FailureRetryDisposition = .none,
        operation: FailureOperation = .unknown,
        origin: FailureOrigin = .unknown,
        diagnosticID: String = UUID().uuidString
    ) {
        self.title = title
        self.reason = reason
        self.recovery = recovery
        self.code = code
        self.condition = condition
        self.action = action
        self.route = route
        self.retryDisposition = retryDisposition
        self.operation = operation
        self.origin = origin
        self.diagnosticID = diagnosticID
    }

    /// 无法由用户自行解决时的统一指引（2026-10-04 死代码审计：11 处硬编码收敛）。
    static let sendLogToAuthor = "把日志发给作者 MJorb"

    static func profileOnlyAppIDMissing(operation: FailureOperation) -> ImportFailure {
        ImportFailure(
            title: "需要完整重签",
            reason: "找不到原应用的 App ID。仅续签不会注册新的 App ID。",
            recovery: "执行完整重签",
            code: "SEAL-PROFILE-337",
            condition: .fullResignRequired,
            action: .fullResign,
            retryDisposition: .none,
            operation: operation,
            origin: .provisioning
        )
    }
}

extension ImportFailure: LocalizedError {
    var errorDescription: String? { title }
    var failureReason: String? { reason }
    var recoverySuggestion: String? { recovery }
}

extension ImportFailure {
    /// 是否已由生产边界赋予新失败合同。
    ///
    /// 历史构造点仍会以默认值创建 `ImportFailure`；UI 在迁移期间只能让这些旧失败
    /// 继续走兼容逻辑，不能把默认 `.copyDiagnostics` 误当作“知道了”。
    var hasStructuredSemantics: Bool {
        condition != .unexpected
            || action != .copyDiagnostics
            || route != nil
            || retryDisposition != .none
            || operation != .unknown
            || origin != .unknown
    }

    var userReason: String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "来源未返回明确原因。" }
        return trimmed
    }

    var userMessage: String {
        userReason
    }
}
