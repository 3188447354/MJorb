import pathlib
import unittest


REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[2]
SINGLE_ACTION_ALERT_SOURCES = (
    "Seal/Features/Apps/AppDetailView.swift",
    "Seal/Features/Apps/AppSigningSheet.swift",
    "Seal/Features/Apps/AppsRootView.swift",
)


class SingleActionAlertTests(unittest.TestCase):
    def test_single_action_failure_alerts_use_dismiss_button_initializer(self) -> None:
        """SwiftUI Alert(primaryButton:) requires a secondary button as well."""
        for relative_path in SINGLE_ACTION_ALERT_SOURCES:
            source = (REPOSITORY_ROOT / relative_path).read_text(encoding="utf-8")
            self.assertIn("dismissButton: .default(Text(failure.recovery))", source, relative_path)
            self.assertNotIn("primaryButton: .default(Text(failure.recovery))", source, relative_path)


if __name__ == "__main__":
    unittest.main()
