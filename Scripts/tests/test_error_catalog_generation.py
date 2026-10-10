import unittest

from Scripts.error_catalog import generate_help_index


class ErrorCatalogGenerationTests(unittest.TestCase):
    def test_generated_index_is_sorted_and_has_no_timestamp(self) -> None:
        index = generate_help_index([
            {
                "code": "SEAL-Z-001",
                "kind": "diagnostic",
                "confidence": "unknown",
                "summary": "z",
                "notEvidenceOf": ["x"],
                "actions": [{"title": "导出日志"}],
                "source": ["Seal/Z.swift"],
            },
            {
                "code": "SEAL-A-001",
                "kind": "failure",
                "confidence": "confirmed",
                "summary": "a",
                "evidence": ["state"],
                "actions": [{"title": "重试"}],
                "source": ["Seal/A.swift"],
            },
        ])

        self.assertEqual(
            [entry["code"] for entry in index["entries"]],
            ["SEAL-A-001", "SEAL-Z-001"],
        )
        self.assertEqual(index["schemaVersion"], 1)
        self.assertNotIn("generatedAt", index)


if __name__ == "__main__":
    unittest.main()
