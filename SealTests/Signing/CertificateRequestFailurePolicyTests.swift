import AltSign
import Foundation
import Testing
@testable import Seal

struct CertificateRequestFailurePolicyTests {
    @Test
    func typedCertificateLimitAndNSErrorBridgeAreRecognized() {
        let error = ALTAppleAPIError(.tooManyCertificates)
        let bridged = error as NSError
        let equivalent = NSError(domain: bridged.domain, code: bridged.code)

        #expect(CertificateRequestFailurePolicy.isCertificateLimitError(error))
        #expect(CertificateRequestFailurePolicy.isCertificateLimitError(equivalent))
        #expect(CertificateRequestFailurePolicy.requestFailure(error: error)?.code == "SEAL-CERT-204b")
        #expect(CertificateRequestFailurePolicy.requestFailure(error: equivalent, limitCode: "SEAL-CERT-204")?.code == "SEAL-CERT-204")
    }

    @Test
    func invalidCSRIsNeverClassifiedAsCertificateLimit() {
        let error = ALTAppleAPIError(.invalidCertificateRequest)
        let bridged = error as NSError
        let equivalent = NSError(domain: bridged.domain, code: bridged.code)

        #expect(!CertificateRequestFailurePolicy.isCertificateLimitError(error))
        #expect(!CertificateRequestFailurePolicy.isCertificateLimitError(equivalent))
        #expect(CertificateRequestFailurePolicy.requestFailure(error: error)?.code == "SEAL-CERT-220")
        #expect(CertificateRequestFailurePolicy.requestFailure(error: equivalent)?.code == "SEAL-CERT-220")
    }

    @Test
    func unrelatedCodesAndTextDoNotAuthorizeCertificateCleanup() {
        let limit = ALTAppleAPIError(.tooManyCertificates) as NSError
        let errors = [
            NSError(domain: "ApplePortal", code: 3022),
            NSError(domain: "Unrelated", code: limit.code),
            NSError(domain: "Unrelated", code: 3250),
            NSError(domain: limit.domain, code: 99999),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        ]
        for original in errors {
            let error = NSError(domain: original.domain, code: original.code, userInfo: [
                NSLocalizedDescriptionKey: "3022 maximum number of certificates; too many; invalidCertificateRequest"
            ])
            #expect(!CertificateRequestFailurePolicy.isCertificateLimitError(error))
            #expect(CertificateRequestFailurePolicy.requestFailure(error: error) == nil)
        }
    }

    @Test
    func diagnosticsExcludeUserInfoAndUntrustedDomain() {
        let error = NSError(domain: "person@example.com secret-token", code: 3022, userInfo: [
            NSLocalizedDescriptionKey: "person@example.com password secret-token",
            NSUnderlyingErrorKey: NSError(domain: "secret-token", code: 1)
        ])
        let diagnostic = CertificateRequestFailurePolicy.diagnostic(for: error)
        #expect(diagnostic == "domain=OtherError code=3022")
        #expect(!diagnostic.contains("@"))
        #expect(!diagnostic.contains("secret-token"))

        let invalid = ALTAppleAPIError(.invalidCertificateRequest) as NSError
        let sensitive = NSError(domain: invalid.domain, code: invalid.code, userInfo: error.userInfo)
        let failure = CertificateRequestFailurePolicy.requestFailure(error: sensitive)
        #expect(failure?.reason.contains("person@example.com") == false)
        #expect(failure?.reason.contains("secret-token") == false)
        #expect(CertificateRequestFailurePolicy.diagnostic(for: sensitive).contains("code=\(invalid.code)"))
    }

    @Test(arguments: ["SEAL-CERT-204", "SEAL-CERT-204a", "SEAL-CERT-204b", "SEAL-CERT-204c", "SEAL-CERT-204d", "SEAL-CERT-220", "SEAL-CERT-221"])
    func deterministicCertificateFailuresOfferDismissal(code: String) {
        #expect(CertificateRequestFailurePolicy.isNonRetryableFailure(failure(code)))
    }

    @Test(arguments: ["SEAL-NET-101", "SEAL-CERT-204e", "SEAL-CERT-209", "SEAL-AUTH-107"])
    func networkAndManualRecoveryRemainAvailable(code: String) {
        #expect(!CertificateRequestFailurePolicy.isNonRetryableFailure(failure(code)))
    }

    private func failure(_ code: String) -> ImportFailure {
        ImportFailure(title: "测试", reason: "测试", recovery: "测试", code: code)
    }
}
