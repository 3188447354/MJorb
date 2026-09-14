import Foundation
import Testing
@testable import Seal

/// 写 API（创建签名证书）超时的语义：**超时不是失败**。
///
/// 服务端可能已经建好证书，只是响应没回来；而私钥由 AltSign 在本地生成、只随响应返回，
/// 响应一丢就不可恢复。所以这条路只有三个诚实的出口：对账确认没建、对账确认建了但废了、
/// 以及对账也失败因此「无法确认」。
///
/// 这里锁定的是错误码与文案口径 —— 真实超时路径无法用 ALTAppleAPI 在单测里触发。
struct PortalWriteTimeoutSemanticsTests {
    @Test
    func recognizesURLErrorTimedOut() {
        #expect(ApplePortalSigningService.isTimeoutError(URLError(.timedOut)))
    }

    /// `withAppleTimeout` 之外，AltSign 内部也可能抛出同域的 NSError 形式。
    @Test
    func recognizesNSErrorTimedOutInURLDomain() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(ApplePortalSigningService.isTimeoutError(error))
    }

    /// 非超时错误必须原样上抛，绝不能被当成「结果未知」而吞掉真实原因。
    @Test
    func rejectsNonTimeoutErrors() {
        #expect(ApplePortalSigningService.isTimeoutError(URLError(.notConnectedToInternet)) == false)
        #expect(ApplePortalSigningService.isTimeoutError(URLError(.badServerResponse)) == false)
        #expect(ApplePortalSigningService.isTimeoutError(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)) == false)
    }

    /// 对账发现孤儿证书：必须明确告诉用户私钥已丢失、这张证书不能用于签名，
    /// 并指向真实入口「我的」→「签名证书」。
    @Test
    func foundOrphanTellsUserToRevokeInApp() {
        let failure = ApplePortalSigningService.certificateCreationUnknownFailure(
            .found(serialNumber: "ABCD1234")
        )
        #expect(failure.code == "SEAL-CERT-209b")
        #expect(failure.reason.contains("ABCD1234"))
        #expect(failure.reason.contains("私钥"))
        #expect(failure.recovery.contains("「签名证书」"))
    }

    /// 对账确认没创建：重试是安全的，文案应允许直接重试。
    @Test
    func confirmedNotCreatedAllowsRetry() {
        let failure = ApplePortalSigningService.certificateCreationUnknownFailure(.none)
        #expect(failure.code == "SEAL-CERT-209c")
        #expect(failure.recovery.contains("重试"))
    }

    /// 对账也失败：必须按「未知」处理，并且明确警告盲目重试会多占名额。
    /// 这是本组用例里最容易被改坏的一条 —— 一旦退化成「请重试」，用户就会凭空烧掉证书名额。
    @Test
    func inconclusiveIsReportedAsUnknownNotAsRetry() {
        let failure = ApplePortalSigningService.certificateCreationUnknownFailure(.inconclusive)
        #expect(failure.code == "SEAL-CERT-209d")
        #expect(failure.title.contains("未知"))
        #expect(failure.reason.contains("名额"))
        #expect(failure.recovery.contains("「签名证书」"))
        // 关键：不能只丢一句「请重试」——必须先让用户去确认远端到底有没有多出证书
        #expect(failure.recovery.contains("确认"), "结果未知时必须先引导确认远端状态")
    }

    /// 远端证书还在、本机 P12 私钥却没了：不能继续申请新证书伪装成「证书数量上限」，
    /// 必须明确告诉用户真正缺的是私钥。
    @Test
    func missingLocalPrivateKeyDoesNotPretendToBeACertificateLimit() {
        let failure = ApplePortalSigningService.missingLocalPrivateKeyFailure(serialNumber: "0BF75BE27D4E4")
        #expect(failure.code == "SEAL-CERT-204c")
        #expect(failure.title.contains("私钥"))
        #expect(failure.reason.contains("BF75BE27D4E4"))
        #expect(failure.recovery.contains("原设备或备份"))
        #expect(failure.recovery.contains("关联 App"))
    }

    /// 本机记录绑定的序列号已经被撤销/删除、但账号下还有别的证书时，
    /// 不能继续申请新证书并把问题伪装成「数量上限」。
    @Test
    func staleCertificateBindingExplainsTheMismatch() {
        let failure = ApplePortalSigningService.staleCertificateBindingFailure(
            serialNumber: "0OLD1234",
            availableCertificateCount: 1
        )
        #expect(failure.code == "SEAL-CERT-204d")
        #expect(failure.title.contains("不存在"))
        #expect(failure.reason.contains("OLD1234"))
        #expect(failure.reason.contains("不是本机当前绑定的那张"))
        #expect(failure.recovery.contains("关联 App"))
    }

    /// 三个出口的错误码必须互不相同，否则用户与日志都无法区分发生了什么。
    @Test
    func theThreeOutcomesHaveDistinctCodes() {
        let codes = [
            ApplePortalSigningService.certificateCreationUnknownFailure(.found(serialNumber: "X")).code,
            ApplePortalSigningService.certificateCreationUnknownFailure(.none).code,
            ApplePortalSigningService.certificateCreationUnknownFailure(.inconclusive).code,
        ]
        #expect(Set(codes).count == 3)
    }
}
