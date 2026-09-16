import Foundation
import Testing
@testable import Seal

/// 覆盖 Apple 请求节流与「会话过期」错误分类。
///
/// 背景：抖音这类「主 App + 8 个扩展」的 IPA 需要在 App ID 阶段连续注册 9 个号
///（每个还要 updateFeatures），Phase 2 再连续申请 9 个描述文件。短时间二十余次
/// 连发请求会触发 Apple 侧掐断会话，返回 1100 "Your session has expired. Please log in."。
///
/// 判定它不是真过期的依据（2026-09-16 用户日志）：每一次 AUTH-107 报错前 1–3 秒
/// 都有一条「证书决策」成功日志 —— 证书申请能成功说明 session 在服务端仍然有效。
/// 用户按提示「重新验证 Apple ID」完全无效，因为重新登录后密集请求会再次触发限流。
///
/// 因此这里锁住两道防线：①相邻请求之间留出间隔；②只对真正的 1100 退避重试。
struct AppleRequestThrottleTests {
    @Test
    func throttleSpacesOutConsecutiveRequests() async {
        let throttle = AppleRequestThrottle()
        let startedAt = Date()
        await throttle.wait()
        await throttle.wait()
        await throttle.wait()
        // 3 次调用之间有 2 个间隔，每个下限 0.4 秒。留出余量避免调度抖动造成误报。
        #expect(Date().timeIntervalSince(startedAt) >= 0.7)
    }

    @Test
    func sessionExpiryIsRecognizedByErrorCode() {
        #expect(
            ApplePortalSigningService.isSessionExpiredError(
                NSError(domain: "Apple.APIError", code: 1100)
            )
        )
    }

    @Test
    func sessionExpiryIsRecognizedByAppleMessage() {
        #expect(
            ApplePortalSigningService.isSessionExpiredError(
                NSError(
                    domain: "Apple.APIError",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Your session has expired. Please log in."]
                )
            )
        )
    }

    /// 其他错误绝不能被当成会话过期：名额上限（3013）、Bundle ID 冲突（9400）这类
    /// 本该立即失败的场景若被重试，会被拖成十几秒的假等待，并给出错误的「重新验证」引导。
    @Test
    func unrelatedFailuresAreNotTreatedAsSessionExpiry() {
        #expect(
            !ApplePortalSigningService.isSessionExpiredError(
                NSError(domain: "Apple.APIError", code: 3013)
            )
        )
        #expect(
            !ApplePortalSigningService.isSessionExpiredError(
                NSError(domain: "Apple.APIError", code: 9400)
            )
        )
        // 关键回归点：文案里恰好含 "1100" 不能触发匹配。
        // 早期写法用过 `diagnostic.contains("1100")`，会把形如
        // `com.example.1100.foo` 的 Bundle ID 报错误判成会话过期。
        #expect(
            !ApplePortalSigningService.isSessionExpiredError(
                NSError(
                    domain: "Apple.APIError",
                    code: 0,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "An App ID with Identifier 'com.example.app1100' is not available."
                    ]
                )
            )
        )
    }
}
