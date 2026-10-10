import Foundation
import Testing
@testable import Seal

struct FailureDiagnosticRecordTests {
    @Test
    func diagnosticRedactsEmailAndRequestURL() {
        let url = "https://developerservices2.apple.com/listTeams.action?appleId=user@example.com"
        let error = NSError(
            domain: NSURLErrorDomain,
            code: URLError.timedOut.rawValue,
            userInfo: [NSURLErrorFailingURLStringErrorKey: url]
        )
        let failure = FailureClassifier.classify(
            error,
            operation: .sign,
            origin: .applePortal
        )
        let record = FailureDiagnosticRecord(failure: failure, underlying: error)

        #expect(record.diagnosticID == failure.diagnosticID)
        #expect(record.redactedCause.contains("user@example.com") == false)
        #expect(record.redactedCause.contains(url) == false)
        #expect(record.operation == .sign)
        #expect(record.origin == .applePortal)
    }
}
