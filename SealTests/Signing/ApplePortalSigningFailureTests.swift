import Foundation
import Testing
import AltSign
@testable import Seal

struct ApplePortalSigningFailureTests {
    @Test
    func identifiesAppIDFailuresInsteadOfCollapsingThemIntoGenericSigningFailure() {
        let failure = ApplePortalSigningFailure.make(
            stage: .appID,
            error: NSError(
                domain: "ApplePortal",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "Bundle identifier is unavailable."]
            )
        )

        #expect(failure.code == "SEAL-APPID-302")
        // 占用语义：reason 用「其他开发者账号」表达 Bundle ID 被占，而非塌缩成通用签名失败
        // （reason 现会拼入底层 Apple 错误码便于排查，故不再断言技术细节被隐藏）
        #expect(failure.reason.contains("其他开发者账号"))
    }

    @Test
    func matchesExistingBundleIdentifiersWithoutCaseSensitivity() {
        #expect(
            ApplePortalAppIDResolver.matches(
                existingBundleIdentifier: "com.Example.Demo",
                requestedBundleIdentifier: "com.example.demo"
            )
        )
    }

    @Test
    func certificateLimitFailureDoesNotAuthorizeAutomaticRevocation() {
        let failure = ApplePortalSigningFailure.make(
            stage: .certificate,
            error: ALTAppleAPIError(.tooManyCertificates)
        )

        // 证书上限被细分为 SEAL-CERT-204a；回收已收敛为签名/续签内的无感自动清理，
        // 失败文案不再引导用户手动撤销（证书页已只读）。
        #expect(failure.code == "SEAL-CERT-204a")
        #expect(failure.reason.contains("证书数量已达上限"))
        #expect(failure.recovery.contains("撤销") == false)
    }

    @Test
    func unclassifiedAccountFailureDoesNotForceReverification() {
        let failure = ApplePortalSigningFailure.make(
            stage: .account,
            error: NSError(
                domain: "ApplePortal",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected response"]
            )
        )

        #expect(failure.code == "SEAL-VERIFY-500")
        #expect(AppleServiceFailurePolicy.shouldRequireReverification(failure) == false)
    }

    @Test
    func networkFailureIsSeparatedFromAuthenticationAndTechnicalDetailsAreHidden() {
        let failure = ApplePortalSigningFailure.make(
            stage: .provisioningProfile,
            error: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorTimedOut,
                userInfo: [NSLocalizedDescriptionKey: "The request timed out."]
            )
        )

        #expect(failure.code.hasPrefix("SEAL-NET-"))
        // 安抚语义保留（账号/已签应用不受影响），仅措辞随网络文案重写而更新；技术细节继续隐藏
        #expect(failure.reason.contains("不受影响"))
        #expect(failure.reason.contains("NSURLErrorDomain") == false)
        #expect(failure.reason.contains("-1001") == false)
    }

    /// 创建 App ID 的顺序：**主 App 必须排在最前**（2026-09-17）。
    ///
    /// 这条只在真机上才看得出后果，所以必须由单测钉住：
    /// 免费账号「7 天内最多注册 10 个 App ID」是主 App 与扩展**共享**的名额，
    /// 而扩展创建失败会「丢弃降级」继续签名、**主 App 创建失败则整个签名抛错**。
    /// 若按 Bundle ID 字母序（原实现）先建扩展，扩展会把名额吃光，
    /// 轮到主 App 时名额已空 ⇒ 整个 App 签不上，而名额已经白花。
    @Test
    func ordersAppIDCreationWithTheMainAppFirst() {
        let main = "com.example.demo"

        // ⚠️ 刻意构造「扩展的字母序排在主 App 前面」的形态：
        // `-` 的码位（0x2D）小于 `.` 的码位（0x2E），所以 `com.example.demo-ext` < `com.example.demo`。
        // 这正是字母序会把主 App 排到扩展后面的那种输入。
        let order = ApplePortalAppIDResolver.preparationOrder(
            mappings: [
                "com.example.demo-ext": "com.example.demo-ext",
                "com.example.demo": main,
                "com.example.demo.zzz": "com.example.demo.zzz",
            ],
            mappedMainBundleID: main
        )

        #expect(order.count == 3)
        #expect(order.first?.mapped == main)
        // 主 App 之外仍按字母序：同一份输入必须产生**稳定**输出，
        // 否则重试时顺序会抖，排查日志时对不上。
        #expect(
            order.map { $0.mapped }
                == ["com.example.demo", "com.example.demo-ext", "com.example.demo.zzz"]
        )
    }

    /// `mappings` 里没有主 App 时不能崩、也不能漏项，退化为纯字母序。
    @Test
    func keepsAlphabeticalOrderWhenMainBundleIDIsNotInMappings() {
        let order = ApplePortalAppIDResolver.preparationOrder(
            mappings: ["com.example.b": "com.example.b", "com.example.a": "com.example.a"],
            mappedMainBundleID: "com.example.missing"
        )

        #expect(order.count == 2)
        #expect(order.map { $0.original } == ["com.example.a", "com.example.b"])
    }
}
