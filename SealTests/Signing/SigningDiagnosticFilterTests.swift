import Foundation
import Testing
@testable import Seal

/// 签名器诊断的**过滤规则**。
///
/// 背景（2026-09-19 真机，构建 151）：打开签名器诊断之后，它对**每个** bundle
/// （含 `BDAlogProtocol.bundle` 这类纯资源包）和每个 Mach-O 各打一行 ⇒
/// 抖音一次 **200+ 行**，把 1000 条的环形缓冲占满，**阶段 / 耗时 / 错误全被挤掉** ✗
///（实测那一份日志里 204/240 行都是「重签：」✗）。
///
/// ⇒ 过滤太松会刷爆日志、太紧会丢掉崩溃点 —— 两种都**不编译失败、也不崩**，
/// 所以必须由单测钉住 ✓。
///
/// ⚠️ 守卫 R48 会核对本文件里这四条断言**确实存在** —— 删掉等于把过滤约束一起删掉。
struct SigningDiagnosticFilterTests {

    @Test
    func signedCodeAlwaysPasses() {
        // 真正签的 Mach-O —— 定位崩溃靠的就是它，**任何情况都不能被过滤掉**
        #expect(ApplePortalSigningService.isUsefulSigningDiagnostic(
            "signedCode=/x/Payload/Aweme.app/Frameworks/AudioXAAC.framework/AudioXAAC"
        ))
        // 连非标准后缀也要放行：只看 `signedCode=` 这个标记，不看路径后缀
        #expect(ApplePortalSigningService.isUsefulSigningDiagnostic("signedCode=/x/SomeBinary"))
    }

    @Test
    func executableContainersPass() {
        for suffix in [".app", ".appex", ".framework"] {
            let message = "sealedBundle=/x/Payload/Aweme.app/Frameworks/Thing\(suffix)"
            #expect(
                ApplePortalSigningService.isUsefulSigningDiagnostic(message),
                "\(suffix) 是有身份的可执行容器，应当放行"
            )
        }
    }

    @Test
    func resourceBundlesAreDropped() {
        // 抖音有 150+ 个这种纯资源包 —— 它们**不是** Mach-O，
        // 每多一行就挤掉一条真正有用的记录 ✗
        let resourceBundles = [
            "sealedBundle=/x/Payload/Aweme.app/BDAlogProtocol.bundle",
            "sealedBundle=/x/Payload/Aweme.app/CameraResource_douyin.bundle",
            "sealedBundle=/x/Payload/Aweme.app/EffectPlatformSDK.bundle/model.bundle",
        ]
        for message in resourceBundles {
            #expect(ApplePortalSigningService.isUsefulSigningDiagnostic(message) == false, "\(message)")
        }
    }

    @Test
    func unrelatedMessagesAreDropped() {
        #expect(ApplePortalSigningService.isUsefulSigningDiagnostic(">>> Signing: /x") == false)
        #expect(ApplePortalSigningService.isUsefulSigningDiagnostic("") == false)
    }
}
