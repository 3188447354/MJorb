import Foundation

/// 本地账号库没有可用于签名的账号时的唯一失败出口。
///
/// “完全没有账号”和“账号存在但需要重新验证”会进入同一个签名前检查，
/// 但用户能执行的动作不同，不能再共用一个错误码或一段二义文案。
enum AccountAvailabilityFailure {
    static func missingAccount(operation: FailureOperation) -> ImportFailure {
        ImportFailure(
            title: "缺少签名账号",
            reason: "尚未添加可用于签名的 Apple ID。",
            recovery: "前往「我的」添加 Apple ID",
            code: "SEAL-AUTH-104h",
            condition: .signingAccountUnavailable,
            action: .addAccount,
            route: .account,
            retryDisposition: .manual,
            operation: operation,
            origin: .authentication
        )
    }

    static func accountNeedsVerification(operation: FailureOperation) -> ImportFailure {
        ImportFailure(
            title: "Apple ID 需要重新验证",
            reason: "已添加的 Apple ID 当前都不能用于签名。",
            recovery: "前往「我的」重新验证 Apple ID",
            code: "SEAL-AUTH-104i",
            condition: .accountVerificationRequired,
            action: .reauthenticateAccount,
            route: .account,
            retryDisposition: .manual,
            operation: operation,
            origin: .authentication
        )
    }
}
