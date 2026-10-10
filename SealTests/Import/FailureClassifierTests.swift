import Foundation
import Testing
@testable import Seal

struct FailureClassifierTests {
    @Test
    func appleTimeoutKeepsOneActionAcrossSigningFlows() {
        for operation in [FailureOperation.sign, .renew, .batchRenew] {
            let failure = FailureClassifier.classify(
                URLError(.timedOut),
                operation: operation,
                origin: .applePortal
            )

            #expect(failure.condition == .appleServiceUnavailable)
            #expect(failure.action == .retry)
            #expect(failure.retryDisposition == .manual)
            #expect(failure.code == "SEAL-NET-102")
            #expect(failure.operation == operation)
            #expect(failure.origin == .applePortal)
        }
    }

    @Test
    func existingFailureKeepsItsConfirmedSemantics() {
        let source = ImportFailure.profileOnlyAppIDMissing(operation: .renew)
        let classified = FailureClassifier.classify(
            source,
            operation: .batchRenew,
            origin: .applePortal
        )

        #expect(classified == source)
        #expect(classified.action == .fullResign)
        #expect(classified.operation == .renew)
    }
}
