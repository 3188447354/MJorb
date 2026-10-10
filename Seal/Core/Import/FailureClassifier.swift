import Foundation

/// 原始异常进入 UI/日志前的唯一归类边界。
///
/// 这里仅根据已验证的系统错误域和现有 `ImportFailure` 归类；不通过错误码前缀猜测原因。
enum FailureClassifier {
    static func classify(
        _ error: Error,
        operation: FailureOperation,
        origin: FailureOrigin
    ) -> ImportFailure {
        if let failure = error as? ImportFailure {
            return failure
        }

        if AppleServiceFailurePolicy.isRateLimited(error) {
            return ImportFailure(
                title: "Apple 服务暂时繁忙",
                reason: "Apple 开发者服务暂时无法处理请求。",
                recovery: "稍后重试",
                code: "SEAL-NET-503",
                // HTTP 503 只能证明 Apple 服务暂不可用；不能推断为用户当前线路被限流。
                condition: .appleServiceUnavailable,
                action: .waitThenRetry,
                retryDisposition: .manual,
                operation: operation,
                origin: origin
            )
        }

        if AppleServiceFailurePolicy.isNetworkError(error) {
            return ImportFailure(
                title: "暂时无法连接 Apple",
                reason: "与 Apple 开发者服务的请求没有完成。",
                recovery: "稍后重试",
                code: "SEAL-NET-102",
                condition: .appleServiceUnavailable,
                action: .retry,
                retryDisposition: .manual,
                operation: operation,
                origin: origin
            )
        }

        return ImportFailure(
            title: title(for: operation),
            reason: "操作未能完成，Seal 尚未确认具体原因。",
            recovery: "复制诊断信息后重试",
            code: fallbackCode(for: operation),
            condition: .unexpected,
            action: .copyDiagnostics,
            retryDisposition: .none,
            operation: operation,
            origin: origin
        )
    }

    private static func title(for operation: FailureOperation) -> String {
        switch operation {
        case .sign: return "签名失败"
        case .renew: return "续签失败"
        case .batchRenew: return "全部续签失败"
        case .authenticateAccount: return "添加账号失败"
        case .install: return "安装失败"
        case .importIPA: return "导入失败"
        case .exportLog: return "日志导出失败"
        case .unknown: return "操作失败"
        }
    }

    private static func fallbackCode(for operation: FailureOperation) -> String {
        switch operation {
        case .sign: return "SEAL-SIGN-500"
        case .renew, .batchRenew: return "SEAL-RENEW-500"
        case .authenticateAccount: return "SEAL-AUTH-500"
        case .install: return "SEAL-INSTALL-500"
        case .importIPA: return "SEAL-IMPORT-500"
        case .exportLog: return "SEAL-LOG-500"
        case .unknown: return "SEAL-UNKNOWN-500"
        }
    }
}
