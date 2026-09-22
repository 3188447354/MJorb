import Foundation
import Testing
@testable import Seal

/// 「Apple 要求双重认证」这条分类的测试。
///
/// **为什么值得单独测**：它的错法不崩、不编译失败，只在真机上把用户引错方向 ——
/// 2026-09-17 真机（构建 95）上，Apple 返回 `Code：3018 /
/// This account requires signing in with two-factor authentication.` 时，
/// 界面给的是「Apple ID 验证失败 / 重试；如持续失败请核对 Apple ID 与密码」。
/// 而**密码完全没问题**：Apple 已经接受了密码，只是要求走第二步。
@Suite("Apple 要求双重认证：分类与提示")
struct AppleAuthenticationDiagnosisTests {
    /// 真机取证的那一条：域 `AltStore.AppleDeveloperError`、码 `3018`。
    private func twoFactorError() -> NSError {
        NSError(
            domain: "AltStore.AppleDeveloperError",
            code: 3018,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "This account requires signing in with two-factor authentication."
            ]
        )
    }

    @Test
    func code3018IsRecognisedAsTwoFactorRequired() {
        let required = AppleAuthenticationDiagnosis.isTwoFactorRequired(twoFactorError())
        #expect(required)
    }

    /// 错误码对不上时用描述兜底 —— 万一 Apple 换了码，提示至少还是对的。
    @Test
    func descriptionMarkerIsTheFallbackWhenTheCodeDiffers() {
        let error = NSError(
            domain: "AltStore.AppleDeveloperError",
            code: 9999,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "This account requires signing in with two-factor authentication."
            ]
        )
        let required = AppleAuthenticationDiagnosis.isTwoFactorRequired(error)
        #expect(required)
    }

    /// 不能把普通认证失败也认成双重认证 —— 那会把「密码错了」说成「需要验证码」。
    @Test
    func unrelatedAppleErrorsAreNotTwoFactor() {
        let wrongPassword = NSError(
            domain: "AltStore.AppleDeveloperError",
            code: 1100,
            userInfo: [NSLocalizedDescriptionKey: "Invalid credentials."]
        )
        let wrongPasswordIsTwoFactor = AppleAuthenticationDiagnosis.isTwoFactorRequired(wrongPassword)
        #expect(wrongPasswordIsTwoFactor == false)

        let timeoutIsTwoFactor = AppleAuthenticationDiagnosis.isTwoFactorRequired(URLError(.timedOut))
        #expect(timeoutIsTwoFactor == false)
    }

    /// **这是本文件最重要的一条**：提示里绝不能出现「核对 Apple ID 与密码」。
    ///
    /// 抽成纯函数就是为了能在这里钉住 —— 源码断言只能证明「有这么个分支」，
    /// 证明不了它的文案没把用户引向一个正确的密码。
    @Test
    func twoFactorFailureNeverTellsTheUserToCheckThePassword() {
        let failure = AppleAuthenticationDiagnosis.twoFactorFailure(for: twoFactorError())

        #expect(failure.title.contains("双重认证"))
        #expect(failure.recovery.contains("密码") == false)
        // 引导必须落在「验证码」这条正确的路上。
        #expect(failure.recovery.contains("验证码"))
        #expect(failure.code == "SEAL-AUTH-101a")
    }

    /// 原始 Apple 现场必须留在文案里 —— 排障时导出的日志只有这一处能看到
    /// 「到底是不是 3018」。丢了它，下次再遇到就只能靠猜。
    @Test
    func twoFactorFailureKeepsTheRawAppleDetail() {
        let failure = AppleAuthenticationDiagnosis.twoFactorFailure(for: twoFactorError())

        #expect(failure.reason.contains("Code：3018"))
        #expect(failure.reason.contains("AltStore.AppleDeveloperError"))
        #expect(failure.reason.contains("two-factor authentication"))
    }

    /// 新错误码**不能**落进「凭据失效」那一组：那会把账号标成需要重新验证，
    /// 而这里账号和密码都是好的，只是第二步没走完。
    @Test
    func twoFactorFailureIsNotClassifiedAsCredentialsRejected() {
        let failure = AppleAuthenticationDiagnosis.twoFactorFailure(for: twoFactorError())
        let reason = AppleServiceFailurePolicy.verificationFailureReason(for: failure)
        #expect(reason == nil)
        let requiresReverification = AppleServiceFailurePolicy.shouldRequireReverification(failure)
        #expect(requiresReverification == false)
    }

    /// 端到端：`make` 必须把 3018 路由到这条提示，而不是泛化的 SEAL-AUTH-107a。
    /// 这条是真正的回归护栏 —— 只测分类函数的话，把 `make` 里的分支删掉不会红。
    @Test
    func makeRoutes3018ToTheTwoFactorFailure() {
        let failure = AppleAuthenticationFailure.make(stage: .signIn, error: twoFactorError())
        #expect(failure.code == "SEAL-AUTH-101a")
        #expect(failure.recovery.contains("密码") == false)
    }

    /// detail 里要带嵌套错误 —— 底层失败常常藏在 `NSUnderlyingErrorKey` 里。
    @Test
    func detailIncludesTheUnderlyingError() {
        let underlying = NSError(
            domain: "com.apple.gsa",
            code: -22406,
            userInfo: [NSLocalizedDescriptionKey: "Authentication required"]
        )
        let error = NSError(
            domain: "AltStore.AppleDeveloperError",
            code: 3018,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "This account requires signing in with two-factor authentication.",
                NSUnderlyingErrorKey: underlying
            ]
        )
        let detail = AppleAuthenticationDiagnosis.detail(for: error)
        #expect(detail.contains("嵌套：com.apple.gsa/-22406"))
        #expect(detail.contains("Code：3018"))
    }
}
