import Foundation
import Testing
@testable import Seal

struct FailureContractTests {
    @Test
    func legacyFailureGetsSafeUnknownSemantics() {
        let failure = ImportFailure(
            title: "签名失败",
            reason: "未知",
            recovery: "复制诊断",
            code: "SEAL-SIGN-500"
        )

        #expect(failure.condition == .unexpected)
        #expect(failure.action == .copyDiagnostics)
        #expect(failure.route == nil)
        #expect(failure.retryDisposition == .none)
        // 旧调用点没有声明操作边界时，不能凭错误码猜它来自签名流程。
        #expect(failure.operation == .unknown)
        #expect(failure.origin == .unknown)
        #expect(failure.hasStructuredSemantics == false)
        #expect(failure.diagnosticID.isEmpty == false)
    }

    @Test
    func profileOnlyMissingAppIDRequiresFullResign() {
        let failure = ImportFailure.profileOnlyAppIDMissing(operation: .renew)

        #expect(failure.code == "SEAL-PROFILE-337")
        #expect(failure.condition == .fullResignRequired)
        #expect(failure.action == .fullResign)
        #expect(failure.route == nil)
        #expect(failure.retryDisposition == .none)
        #expect(failure.operation == .renew)
        #expect(failure.origin == .provisioning)
        #expect(failure.hasStructuredSemantics)
    }

    @Test
    func unavailableAndUnverifiedAccountsHaveDifferentPrimaryActions() {
        let missing = AccountAvailabilityFailure.missingAccount(operation: .sign)
        let unverified = AccountAvailabilityFailure.accountNeedsVerification(operation: .renew)

        #expect(missing.code == "SEAL-AUTH-104h")
        #expect(missing.action == .addAccount)
        #expect(missing.operation == .sign)
        #expect(unverified.code == "SEAL-AUTH-104i")
        #expect(unverified.action == .reauthenticateAccount)
        #expect(unverified.operation == .renew)
    }

    @Test
    func equalFailuresIncludeFailureSemantics() {
        let first = ImportFailure(
            title: "签名失败",
            reason: "未知",
            recovery: "复制诊断",
            code: "SEAL-SIGN-500",
            diagnosticID: "diagnostic-a"
        )
        let second = ImportFailure(
            title: "签名失败",
            reason: "未知",
            recovery: "复制诊断",
            code: "SEAL-SIGN-500",
            diagnosticID: "diagnostic-b"
        )

        #expect(first != second)
    }
}
