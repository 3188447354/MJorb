import Foundation

/// 认证失败的**分类规则**，以及每条分类对应的用户提示 —— 判据与文案放在一起。
///
/// ## 为什么判据和文案不拆开
///
/// 拆开迟早漂移成「判据说这是双重认证、文案却让用户去核对密码」。而这类漂移
/// **不崩、不编译失败**，只在真机上把用户引错方向。
///
/// ## 真机取证（2026-09-17，构建 95）
///
/// 加这个分类之前，Apple 要求双重认证时用户看到的是：
///
/// ```
/// [SEAL-AUTH-107a] Apple ID 验证失败。
/// 类型：ALTAppleAPIError
/// Domain：AltStore.AppleDeveloperError
/// Code：3018
/// 描述：This account requires signing in with two-factor authentication.
/// ```
///
/// 恢复建议写的是「重试；如持续失败请核对 Apple ID 与密码」—— 但**密码在这里完全没问题**：
/// Apple 已经接受了密码，只是要求走第二步。用户会在一个正确的密码上反复试，
/// 甚至跑去重置密码。
///
/// 分类与文案都做成纯函数，是为了能单测 —— 这类错法的共同点是「只在真机上可见」。
enum AppleAuthenticationDiagnosis {
    /// Apple 在登录阶段要求双重认证时返回的错误码。
    ///
    /// 真机上与它同时出现的还有域 `AltStore.AppleDeveloperError`
    /// 与描述 `This account requires signing in with two-factor authentication.`
    static let twoFactorRequiredCode = 3018

    /// 描述文本兜底用的关键词。
    ///
    /// **只在错误码对不上时才用**：描述会随 Apple 的措辞与语言变，错误码不会。
    /// 留兜底的收益是「万一 Apple 换了码，提示至少还是对的」；
    /// 代价只是可能把别的错误显示成双重认证提示 —— 这条判据**只影响文案**，
    /// 不影响任何破坏性行为，所以宁可宽松一点。
    static let twoFactorDescriptionMarker = "two-factor authentication"

    /// Apple 是否要求这个账号用双重认证登录。
    static func isTwoFactorRequired(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == twoFactorRequiredCode { return true }
        return nsError.localizedDescription
            .localizedCaseInsensitiveContains(twoFactorDescriptionMarker)
    }

    /// 错误详情串 —— 排障时唯一能拿到的现场。
    ///
    /// **只有这一处实现**。此前 `AppleAuthenticationFailure.make` 与
    /// `AppleAccountClient.failure(from:)` 各抄了一份完全相同的构造，
    /// 而那种重复在本仓库反复漂移成「修了一条、漏了另一条」。
    static func detail(for error: Error) -> String {
        let nsError = error as NSError
        var parts: [String] = []
        parts.append("类型：\(String(describing: type(of: error)))")
        parts.append("Domain：\(nsError.domain)")
        parts.append("Code：\(nsError.code)")
        parts.append("描述：\(nsError.localizedDescription)")
        if let debugDescription = nsError.userInfo["NSDebugDescription"] as? String {
            parts.append("调试：\(debugDescription)")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("嵌套：\(underlying.domain)/\(underlying.code) \(underlying.localizedDescription)")
        }
        return parts.joined(separator: "\n")
    }

    /// 「Apple 要求双重认证、但这一步没走完」的用户提示。
    ///
    /// ## 绝不复用泛化的「Apple ID 验证失败 / 核对 Apple ID 与密码」
    ///
    /// 那会把用户引向一个正确的密码。守卫与单测都钉住这一点。
    ///
    /// ## 错误码选 `SEAL-AUTH-101a` 而不是新号段
    ///
    /// `SEAL-AUTH-101` 是「验证码被 Apple 拒绝」，本条是「验证码这一步没走完」——
    /// 同一族，日志里按 `SEAL-AUTH-101` 前缀扫能一次看全。
    /// 另外它**不能**落进 `AppleServiceFailurePolicy.verificationFailureReason` 里
    /// `SEAL-AUTH-102` / `-105` / `-106` 那几组：那几组会把账号标记成「凭据失效」，
    /// 而这里账号和密码都是好的。
    static func twoFactorFailure(for error: Error) -> ImportFailure {
        ImportFailure(
            title: "Apple ID 需要双重认证",
            reason: "Apple 要求这个 Apple ID 用双重认证登录，但本次认证没有走完第二步。\n"
                + "常见原因：验证码输入被取消或超时；或这台设备还不是该 Apple ID 的受信任设备，收不到验证码。\n"
                + detail(for: error),
            recovery: "重新添加账号，在弹出的「输入验证码」里填 Apple 发来的六位数字；"
                + "若始终收不到验证码，先到系统「设置 → 你的名字」用这个 Apple ID 登录一次，再回来重试",
            code: "SEAL-AUTH-101a"
        )
    }
}
