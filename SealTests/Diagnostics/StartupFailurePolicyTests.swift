import Foundation
import Testing
@testable import Seal

struct StartupFailurePolicyTests {
    @Test
    func storageStartupFailureDoesNotClaimTheDeviceIsFull() {
        let failure = StartupFailurePolicy.failure(
            for: NSError(domain: "CoreData", code: 134110)
        )

        #expect(failure.code == "SEAL-APP-001")
        #expect(failure.condition == .localStorageWriteFailed)
        #expect(failure.action == .restartSeal)
        #expect(failure.origin == .fileStore)
        #expect(failure.reason.contains("存储空间") == false)
    }

    @Test
    func preservesAnAlreadyClassifiedFailure() {
        let original = ImportFailure.profileOnlyAppIDMissing(operation: .renew)

        #expect(StartupFailurePolicy.failure(for: original) == original)
    }
}
