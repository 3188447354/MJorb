import unittest

from Scripts.error_catalog import validate_catalog


class ErrorCatalogValidationTests(unittest.TestCase):
    def test_confirmed_entry_requires_evidence(self) -> None:
        entry = {
            "code": "SEAL-AUTH-102c",
            "kind": "failure",
            "confidence": "confirmed",
            "summary": "账号状态无法继续本次请求。",
            "actions": [{"title": "重新验证 Apple ID"}],
            "source": ["Seal/Infrastructure/Accounts/AppleAccountClient.swift"],
        }

        result = validate_catalog([entry])

        self.assertEqual(
            result.errors,
            ["SEAL-AUTH-102c: confirmed entries require evidence"],
        )

    def test_unknown_entry_requires_non_inference(self) -> None:
        entry = {
            "code": "SEAL-AUTH-999",
            "kind": "failure",
            "confidence": "unknown",
            "summary": "无法分类的账号错误。",
            "actions": [{"title": "导出日志"}],
            "source": ["Seal/Infrastructure/Accounts/AppleAccountClient.swift"],
        }

        result = validate_catalog([entry])

        self.assertTrue(
            any("unknown entries require notEvidenceOf" in error for error in result.errors)
        )


if __name__ == "__main__":
    unittest.main()
