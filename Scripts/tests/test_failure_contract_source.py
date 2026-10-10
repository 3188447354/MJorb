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


if __name__ == "__main__":
    unittest.main()
