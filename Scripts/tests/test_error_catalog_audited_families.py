import unittest
from pathlib import Path

from Scripts.error_catalog import load_catalog


class ErrorCatalogAuditedFamilyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        root = Path(__file__).resolve().parents[2]
        cls.entries = {
            entry["code"]: entry
            for entry in load_catalog(root / "docs" / "error-catalog")
        }

    def test_install_timeout_does_not_prove_installation_failed(self) -> None:
        entry = self.entries["SEAL-INSTALL-702t"]
        self.assertEqual(entry["confidence"], "conditional")
        self.assertIn("安装未完成", entry["notEvidenceOf"])

    def test_profile_check_is_diagnostic_not_terminal_failure(self) -> None:
        entry = self.entries["SEAL-PROFILE-363"]
        self.assertEqual(entry["kind"], "diagnostic")
        self.assertEqual(entry["confidence"], "conditional")
        self.assertIn("描述文件注入失败", entry["notEvidenceOf"])

    def test_no_space_has_kernel_evidence(self) -> None:
        entry = self.entries["SEAL-INSTALL-702s"]
        self.assertEqual(entry["confidence"], "confirmed")
        self.assertIn("ENOSPC", entry["evidence"])

    def test_self_replacement_unexpected_error_remains_unknown(self) -> None:
        entry = self.entries["SEAL-SELF-109"]
        self.assertEqual(entry["confidence"], "unknown")
        self.assertTrue(any("证书失效" in item for item in entry["notEvidenceOf"]))

    def test_temporary_cleanup_failure_retains_its_underlying_reason(self) -> None:
        entry = self.entries["SEAL-STORAGE-004"]
        self.assertEqual(entry["confidence"], "unknown")
        self.assertTrue(any("用户应用数据" in item for item in entry["notEvidenceOf"]))


if __name__ == "__main__":
    unittest.main()
