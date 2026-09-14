import Foundation

enum AppleServiceFailurePolicy {
    static func isNetworkError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return networkCodes.contains(urlError.code)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            if networkCodes.contains(code) {
                return true
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           isNetworkError(underlying) {
            return true
        }

        let message = nsError.localizedDescription.lowercased()
        return networkFragments.contains(where: message.contains)
    }

    static func networkFailure(
        underlying _: Error? = nil,
        title: String = "连不上 Apple",
        reason: String = "连不上 Apple 服务器，请检查网络或梯子。已保存的 Apple ID 不受影响。",
        recovery: String = "网络恢复后重试",
        code: String = "SEAL-NET-101"
    ) -> ImportFailure {
        ImportFailure(
            title: title,
            reason: reason,
            recovery: recovery,
            code: code
        )
    }

    /// Apple 服务端返回 503（线路被限流/出口不对）。这是「线路」问题，重试也通不了，
    /// 单独识别出来直接提示切换非国内梯子，不进入网络错误的重试循环。
    static func isRateLimited(_ error: Error) -> Bool {
        let ns = error as NSError
        if messageIndicates503(ns.localizedDescription) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error,
           isRateLimited(underlying) { return true }
        return false
    }

    /// 503 专属失败：直接给可执行动作（切非国内梯子），不假装「检查网络后重试」。
    static func rateLimitedFailure(underlying _: Error? = nil) -> ImportFailure {
        ImportFailure(
            title: "连不上 Apple",
            reason: "连不上 Apple 服务器，多半是当前网络线路被限流了。",
            recovery: "切换到非国内梯子（海外节点）后重试",
            code: "SEAL-NET-503"
        )
    }

    private static func messageIndicates503(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("503") || m.contains("service temporarily unavailable")
    }

    static func verificationFailureReason(
        for failure: ImportFailure
    ) -> AccountVerificationFailureReason? {
        let code = failure.code
        // SEAL-AUTH-105f 是 Team 查询失败，不代表本地凭据缺失，不得标记 needsVerification。
        if code == "SEAL-AUTH-105f" { return nil }
        if code.hasPrefix("SEAL-AUTH-102") { return .credentialsRejected }
        if code.hasPrefix("SEAL-AUTH-105") { return .localCredentialsMissing }
        if code.hasPrefix("SEAL-AUTH-106") { return .localCredentialsMismatch }
        // SEAL-AUTH-107（会话过期）不标记 ID 失效：签名/续签在 LocalDevVPN 环境无法可靠自动重登，
        // 统一引导到「我的」页重新验证；网络/限流也不写账号状态。
        return nil
    }

    static func shouldRequireReverification(_ failure: ImportFailure) -> Bool {
        verificationFailureReason(for: failure) != nil
    }

    static func isTransient(_ failure: ImportFailure) -> Bool {
        failure.code.hasPrefix("SEAL-NET-")
            || failure.code.hasPrefix("SEAL-ANI-")
            || failure.code == "SEAL-CERT-205"
    }

    private static let networkCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
        .networkConnectionLost,
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .internationalRoamingOff,
        .dataNotAllowed,
        .callIsActive,
        .resourceUnavailable
    ]

    private static let networkFragments = [
        "network",
        "timed out",
        "timeout",
        "not connected",
        "offline",
        "cannot connect",
        "could not connect",
        "cannot find host",
        "dns"
    ]
}
