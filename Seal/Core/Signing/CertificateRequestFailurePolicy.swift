import AltSign
import Foundation

/// Only AltSign's typed certificate quota error authorizes quota recovery.
/// Invalid CSR errors and unrelated numeric/text matches must not trigger revocation.
enum CertificateRequestFailurePolicy {
    static func isCertificateLimitError(_ error: Error) -> Bool {
        matches(error, expected: ALTAppleAPIError(.tooManyCertificates))
    }

    static func requestFailure(
        error: Error,
        limitCode: String = "SEAL-CERT-204b"
    ) -> ImportFailure? {
        if isCertificateLimitError(error) {
            return ImportFailure(
                title: "签名证书数量已达上限",
                reason: "Apple 已明确拒绝新增签名证书：该账号证书数量已达上限。诊断：\(diagnostic(for: error))",
                recovery: "请先在原签名工具确认现有证书用途，完成签名身份迁移后再续签。",
                code: limitCode
            )
        }
        if matches(error, expected: ALTAppleAPIError(.invalidCertificateRequest)) {
            return ImportFailure(
                title: "签名证书请求无效",
                reason: "无法生成有效证书请求，或 Apple 拒绝了本次请求；此错误不代表证书名额已满。诊断：\(diagnostic(for: error))",
                recovery: "请导出日志排查证书请求；不要为此撤销现有证书。",
                code: "SEAL-CERT-220"
            )
        }
        return nil
    }

    /// Preserve actionable machine diagnostics without copying descriptions, responses,
    /// underlying errors, or arbitrary domain strings that can contain credentials.
    static func diagnostic(for error: Error) -> String {
        let nsError = error as NSError
        let appleDomain = (ALTAppleAPIError(.tooManyCertificates) as NSError).domain
        let domain: String
        switch nsError.domain {
        case appleDomain: domain = "ALTAppleAPIErrorDomain"
        case NSURLErrorDomain: domain = "NSURLErrorDomain"
        default: domain = "OtherError"
        }
        return "domain=\(domain) code=\(nsError.code)"
    }

    static func isNonRetryableFailure(_ failure: ImportFailure) -> Bool {
        switch failure.code {
        case "SEAL-CERT-204", "SEAL-CERT-204a", "SEAL-CERT-204b",
             "SEAL-CERT-204c", "SEAL-CERT-204d", "SEAL-CERT-220", "SEAL-CERT-221":
            return true
        default:
            return false
        }
    }

    private static func matches(_ error: Error, expected: Error) -> Bool {
        let actual = error as NSError
        let expected = expected as NSError
        return actual.domain == expected.domain && actual.code == expected.code
    }
}
