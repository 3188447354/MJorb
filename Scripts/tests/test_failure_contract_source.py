"""Static regression checks for failure-contract fields until macOS CI compiles Swift."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class FailureContractSourceTests(unittest.TestCase):
    def test_service_unavailable_factory_has_no_network_route_guess(self) -> None:
        source = (ROOT / "Seal/Core/Accounts/AppleServiceFailurePolicy.swift").read_text(
            encoding="utf-8"
        )
        factory = source.split("static func rateLimitedFailure", 1)[1].split(
            "private static func messageIndicates503", 1
        )[0]

        self.assertIn("condition: .appleServiceUnavailable", factory)
        self.assertIn("action: .waitThenRetry", factory)
        self.assertIn("retryDisposition: .manual", factory)
        self.assertIn("origin: .applePortal", factory)
        self.assertNotIn("海外", factory)
        self.assertNotIn("节点", factory)

    def test_two_factor_factory_declares_account_recovery_semantics(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Accounts/AppleAuthenticationDiagnosis.swift").read_text(
            encoding="utf-8"
        )
        factory = source.split("static func twoFactorFailure", 1)[1]

        self.assertIn("condition: .twoFactorAuthenticationRequired", factory)
        self.assertIn("action: .enterNewVerificationCode", factory)
        self.assertIn("route: .account", factory)
        self.assertIn("retryDisposition: .manual", factory)
        self.assertIn("operation: .authenticateAccount", factory)
        self.assertIn("origin: .authentication", factory)

    def test_explicit_account_rejections_keep_their_distinct_recovery_contracts(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Accounts/AppleAccountClient.swift").read_text(
            encoding="utf-8"
        )
        verification_code = source.split(
            "catch ALTAppleAPIError.incorrectVerificationCode", 1
        )[1].split("catch ALTAppleAPIError.incorrectCredentials", 1)[0]
        initial_credentials = source.split(
            "catch ALTAppleAPIError.incorrectCredentials", 1
        )[1].split("catch ALTAppleAPIError.invalidAnisetteData", 1)[0]
        validation_credentials = source.split(
            "func validate(", 1
        )[1].split("catch ALTAppleAPIError.incorrectCredentials", 1)[1].split(
            "catch let failure as ImportFailure", 1
        )[0]

        self.assertIn("condition: .verificationCodeRejected", verification_code)
        self.assertIn("action: .enterNewVerificationCode", verification_code)
        self.assertIn("operation: .authenticateAccount", verification_code)

        self.assertIn("condition: .credentialsRejected", initial_credentials)
        self.assertIn("action: .reauthenticateAccount", initial_credentials)
        self.assertIn("operation: .authenticateAccount", initial_credentials)

        self.assertIn("condition: .credentialsRejected", validation_credentials)
        self.assertIn("action: .reauthenticateAccount", validation_credentials)
        self.assertIn("operation: .validateAccount", validation_credentials)

    def test_missing_and_unverified_accounts_are_not_emitted_as_one_failure(self) -> None:
        source = (ROOT / "Seal/Core/Accounts/AccountAvailabilityFailure.swift").read_text(
            encoding="utf-8"
        )

        self.assertIn('code: "SEAL-AUTH-104h"', source)
        self.assertIn("condition: .signingAccountUnavailable", source)
        self.assertIn("action: .addAccount", source)
        self.assertIn('code: "SEAL-AUTH-104i"', source)
        self.assertIn("condition: .accountVerificationRequired", source)
        self.assertIn("action: .reauthenticateAccount", source)

    def test_recorded_renewal_account_failures_keep_their_team_safe_actions(self) -> None:
        source = (ROOT / "Seal/Features/Apps/AppsViewModel.swift").read_text(
            encoding="utf-8"
        )
        needs_verification = source.split(
            "case .recordedAccountNeedsVerification", 1
        )[1].split("case .recordedAccountMissing", 1)[0]
        missing_original = source.split(
            "case .recordedAccountMissing", 1
        )[1].split("case .noSelectableAccount", 1)[0]

        self.assertIn("condition: .accountVerificationRequired", needs_verification)
        self.assertIn("action: .reauthenticateAccount", needs_verification)
        self.assertIn("operation: .renew", needs_verification)
        self.assertIn("condition: .recordedSigningIdentityUnavailable", missing_original)
        self.assertIn("action: .addAccount", missing_original)
        self.assertIn("operation: .renew", missing_original)

    def test_authentication_timeout_and_team_lookup_keep_distinct_facts(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Accounts/AppleAccountClient.swift").read_text(
            encoding="utf-8"
        )
        timeout = source.split("catch let error as HardTimeout.TimeoutError", 1)[1].split(
            "    }\n\n    /// 自动重新登录", 1
        )[0]
        team_lookup = source.split("case .teamLookup:", 1)[1].split("    }\n}", 1)[0]

        self.assertIn("condition: .authenticationTimedOut", timeout)
        self.assertIn("action: .waitThenRetry", timeout)
        self.assertIn("operation: .authenticateAccount", timeout)
        self.assertNotIn("更换网络", timeout)

        self.assertIn("condition: .developerTeamLookupFailed", team_lookup)
        self.assertIn("action: .retry", team_lookup)
        self.assertIn("operation: .authenticateAccount", team_lookup)

    def test_anisette_factory_distinguishes_rejection_unavailability_and_service_wait(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Accounts/AppleAccountClient.swift").read_text(
            encoding="utf-8"
        )
        factory = source.split("if let anisetteError", 1)[1].split(
            "// 双重认证必须排在", 1
        )[0]

        self.assertIn('code: "SEAL-ANI-110",', factory)
        self.assertIn("condition: .authenticationEnvironmentRejected", factory)
        self.assertIn("condition: .authenticationEnvironmentUnavailable", factory)
        self.assertIn("condition: .authenticationEnvironmentServiceUnavailable", factory)
        self.assertIn("action: .waitThenRetry", factory)
        self.assertIn("operation: .authenticateAccount", factory)
        self.assertIn("origin: .authentication", factory)

    def test_authentication_handshake_rejection_does_not_guess_network_remediation(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Accounts/AppleAccountClient.swift").read_text(
            encoding="utf-8"
        )
        handshake = source.split("case .authenticationHandshakeFailed", 1)[1].split(
            "if error is AnisetteV3Error", 1
        )[0]

        self.assertIn("condition: .authenticationHandshakeRejected", handshake)
        self.assertIn("action: .waitThenRetry", handshake)
        self.assertIn("operation: .authenticateAccount", handshake)
        self.assertNotIn("更换网络", handshake)
        self.assertNotIn("系统时间", handshake)

    def test_incomplete_profile_only_result_retries_instead_of_claiming_app_id_loss(self) -> None:
        source = (ROOT / "Seal/Core/Renewal/ProfileOnlyRenewalRecordUpdater.swift").read_text(
            encoding="utf-8"
        )

        for code in ("340", "341", "342"):
            failure = source.split(f'code: "SEAL-PROFILE-{code}",', 1)[1].split(
                "\n                )", 1
            )[0]
            self.assertIn("condition: .provisioningProfileIncomplete", failure)
            self.assertIn("action: .retry", failure)
            self.assertIn("retryDisposition: .manual", failure)
            self.assertIn("operation: .renew", failure)
            self.assertIn("origin: .provisioning", failure)
            self.assertNotIn("fullResign", failure)

    def test_terminal_install_outcomes_have_distinct_codes_and_actions(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift").read_text(
            encoding="utf-8"
        )
        app_limit = source.split("// 2) 免费账号设备级应用上限", 1)[1].split(
            "// 3) 签名产物完整性", 1
        )[0]
        invalid_artifact = source.split("// 3) 签名产物完整性", 1)[1].split(
            "// 4) `ApplicationVerificationFailed`", 1
        )[0]
        unknown_rejection = source.split("// 4) `ApplicationVerificationFailed`", 1)[1].split(
            "// 5) 设备未连接", 1
        )[0]

        self.assertIn('code: "SEAL-INSTALL-702l"', app_limit)
        self.assertIn("action: .removeInstalledApp", app_limit)
        self.assertIn('code: "SEAL-INSTALL-702v"', invalid_artifact)
        self.assertIn("action: .fullResign", invalid_artifact)
        self.assertIn('code: "SEAL-INSTALL-702u"', unknown_rejection)
        self.assertIn("action: .copyDiagnostics", unknown_rejection)


if __name__ == "__main__":
    unittest.main()
