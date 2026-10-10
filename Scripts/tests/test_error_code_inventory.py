import importlib.util
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "error_code_inventory.py"
SPEC = importlib.util.spec_from_file_location("error_code_inventory", MODULE_PATH)
error_code_inventory = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(error_code_inventory)


class ErrorCodeInventoryTests(unittest.TestCase):
    def write_source(self, source: str) -> Path:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "Example.swift"
        path.write_text(source, encoding="utf-8")
        return path

    def test_extracts_multi_segment_codes_without_truncation(self):
        path = self.write_source(
            'let failure = ImportFailure(title: "x", reason: "x", recovery: "x", '
            'code: "SEAL-UPDATE-DL-501")\n'
        )

        occurrences = error_code_inventory.scan_file(path)

        self.assertEqual([item.code for item in occurrences], ["SEAL-UPDATE-DL-501"])
        self.assertEqual(occurrences[0].role, error_code_inventory.OccurrenceRole.STRUCTURED_FAILURE_EMISSION)

    def test_recognizes_direct_import_failure_construction_as_structured_failure_boundary(self):
        path = self.write_source(
            'return ImportFailure(\n'
            '    title: "x",\n'
            '    reason: "x",\n'
            '    recovery: "x",\n'
            '    code: "SEAL-UPDATE-DL-501"\n'
            ')\n'
        )

        occurrences = error_code_inventory.scan_file(path)

        self.assertEqual(
            occurrences[0].role,
            error_code_inventory.OccurrenceRole.STRUCTURED_FAILURE_EMISSION,
        )

    def test_records_explicit_failure_contract_fields_at_direct_boundary(self):
        path = self.write_source(
            'return ImportFailure(\n'
            '    title: "x",\n'
            '    reason: "x",\n'
            '    recovery: "x",\n'
            '    code: "SEAL-IPA-101",\n'
            '    condition: .invalidArchive,\n'
            '    action: .chooseAnotherIPA,\n'
            '    operation: .import\n'
            ')\n'
        )

        occurrences = error_code_inventory.scan_file(path)

        self.assertEqual(
            occurrences[0].semantic_fields,
            ("condition", "action", "operation"),
        )

    def test_classifies_comment_reference_without_treating_it_as_an_emission(self):
        path = self.write_source('// SEAL-IPA-ROLLBACK-001 is a historical reference\n')

        occurrences = error_code_inventory.scan_file(path)

        self.assertEqual(len(occurrences), 1)
        self.assertEqual(occurrences[0].role, error_code_inventory.OccurrenceRole.COMMENT_REFERENCE)

    def test_classifies_event_code_mapping_separately_from_failure_emission(self):
        path = self.write_source(
            'var code: String {\n'
            '    case .initial: return "SEAL-BACKGROUND-001"\n'
            '}\n'
        )

        occurrences = error_code_inventory.scan_file(path)

        self.assertEqual(occurrences[0].role, error_code_inventory.OccurrenceRole.INTERNAL_EVENT_OR_LOG)

    def test_marks_symbolic_log_tags_as_non_error_identifiers(self):
        path = self.write_source(
            'try? await logStore.append(message: "[SEAL-OP] Start signing")\n'
        )

        occurrences = error_code_inventory.scan_file(path)

        self.assertEqual(occurrences[0].code, "SEAL-OP")
        self.assertEqual(occurrences[0].identifier_kind, error_code_inventory.IdentifierKind.DIAGNOSTIC_TAG)

    def test_marks_emitted_legacy_identifier_for_explicit_migration(self):
        path = self.write_source(
            'throw Self.failure(reason: "x", recovery: "x", code: "SEAL-APPID-DEVICELIMIT")\n'
        )

        occurrences = error_code_inventory.scan_file(path)

        self.assertEqual(occurrences[0].identifier_kind, error_code_inventory.IdentifierKind.LEGACY_ERROR_IDENTIFIER)

    def test_classifies_code_field_inside_log_entry_as_diagnostic_not_failure(self):
        path = self.write_source(
            'let entry = SealLogEntry(\n'
            '    message: "completed",\n'
            '    code: "SEAL-SIGN-SINGLE"\n'
            ')\n'
        )

        occurrences = error_code_inventory.scan_file(path)

        self.assertEqual(occurrences[0].role, error_code_inventory.OccurrenceRole.INTERNAL_EVENT_OR_LOG)
        self.assertEqual(occurrences[0].identifier_kind, error_code_inventory.IdentifierKind.DIAGNOSTIC_TAG)

    def test_classifies_optional_log_store_call_as_diagnostic_not_failure(self):
        path = self.write_source(
            'try? await logStore?.append(\n'
            '    message: "completed",\n'
            '    code: "SEAL-SIGN-SINGLE"\n'
            ')\n'
        )

        occurrences = error_code_inventory.scan_file(path)

        self.assertEqual(occurrences[0].role, error_code_inventory.OccurrenceRole.INTERNAL_EVENT_OR_LOG)

    def test_build_inventory_keeps_all_source_locations_and_does_not_promote_unreviewed_codes(self):
        path = self.write_source(
            'let failure = ImportFailure(code: "SEAL-IPA-101")\n'
            '// SEAL-IPA-101 documents the same condition\n'
        )

        inventory = error_code_inventory.build_inventory(error_code_inventory.scan_file(path), path.parent)

        entry = inventory["codes"]["SEAL-IPA-101"]
        self.assertEqual(entry["auditStatus"], "unreviewed")
        self.assertEqual(entry["occurrenceCount"], 2)
        self.assertEqual(
            entry["roles"],
            {
                "comment_reference": 1,
                "structured_failure_emission": 1,
            },
        )
        self.assertEqual([location["line"] for location in entry["locations"]], [1, 2])
        self.assertEqual(
            inventory["summary"]["structuredFailureContracts"],
            {
                "directOccurrences": 1,
                "withExplicitSemantics": 0,
                "withoutExplicitSemantics": 1,
            },
        )

    def test_audit_status_distinguishes_contracted_mixed_and_diagnostic_identifiers(self):
        path = self.write_source(
            'let contracted = ImportFailure(code: "SEAL-IPA-101", condition: .x)\n'
            'let legacy = ImportFailure(code: "SEAL-IPA-102")\n'
            'let mixed = ImportFailure(code: "SEAL-IPA-103", action: .retry)\n'
            'let mixedLegacy = ImportFailure(code: "SEAL-IPA-103")\n'
            'try? await logStore.append(message: "done", code: "SEAL-OP")\n'
        )

        inventory = error_code_inventory.build_inventory(error_code_inventory.scan_file(path), path.parent)

        self.assertEqual(inventory["codes"]["SEAL-IPA-101"]["auditStatus"], "contracted")
        self.assertEqual(inventory["codes"]["SEAL-IPA-102"]["auditStatus"], "unreviewed")
        self.assertEqual(inventory["codes"]["SEAL-IPA-103"]["auditStatus"], "mixed")
        self.assertEqual(inventory["codes"]["SEAL-OP"]["auditStatus"], "diagnostic_only")


if __name__ == "__main__":
    unittest.main()
