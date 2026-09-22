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
        // ⚠️ **SEAL-AUTH-102c 不得标记失效**（2026-09-18 真机，构建 133）。
        //
        // 它自己的文案就写着「两种常见成因：登录真的失效，**或者短时间内请求过密被 Apple 限流**」
        // 且 recovery 是「**先等几分钟重试**」—— 而把它判成 `.credentialsRejected`
        // 会**立刻把账号标成「失效」**，与这段文案**直接矛盾** ✗。
        //
        // 真机证据：`318***5***@qq.com` 签抖音时
        //   15:00:49  疑似被限流，退避 1 秒后重试 读取证书列表（第 1 次）
        //   15:00:53  第 2 次（退避 4 秒）    15:00:58  第 3 次（退避 8 秒）
        //   15:01:09  [SEAL-AUTH-102c] Apple 拒绝了证书请求：认证状态无效
        // ⇒ 紧接 **3 次限流退避**之后报的 102c，极可能就是限流；账号却被标成「失效」
        //   ⇒ 用户看到「失效 + 已签名 0/10」，于是去重新验证 → 又撞限流 → **死循环**。
        //
        // 语义上也更该保守：`107`（明确的会话过期）已经不标 ✓，而 `102c` 是**二义**的，
        // 更不该标 ✓。注意 **`102d` 保持标记** —— 那是 Apple **明确**拒绝凭据
        //（可能密码已改 / 账号被锁定），语义不含糊。
        if code == "SEAL-AUTH-102c" { return nil }
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
