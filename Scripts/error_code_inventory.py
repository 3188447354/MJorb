#!/usr/bin/env python3
"""Extract evidence-labelled Seal error-code occurrences from production Swift."""

from __future__ import annotations

import re
import argparse
import json
from collections import Counter, defaultdict
from enum import Enum
from pathlib import Path
from typing import NamedTuple


ERROR_CODE_PATTERN = re.compile(
    r"(?<![A-Za-z0-9-])(SEAL-[A-Z0-9]+(?:-[A-Z0-9]+)*(?:[a-z])?)(?![A-Za-z0-9-])"
)
STANDARD_ERROR_CODE_PATTERN = re.compile(r"SEAL-(?:[A-Z0-9]+-)*[0-9]+[a-z]?")
FAILURE_EMISSION_PATTERN = re.compile(r'\bcode\s*[:=]\s*"SEAL-')
EVENT_MAPPING_PATTERN = re.compile(r'\b(return|rawValue|event|log|append)\b', re.IGNORECASE)
STRUCTURED_FAILURE_FIELDS = (
    "condition",
    "action",
    "route",
    "retryDisposition",
    "operation",
    "origin",
)


class OccurrenceRole(str, Enum):
    """A source role, deliberately not a claim that an error reaches the UI."""

    STRUCTURED_FAILURE_EMISSION = "structured_failure_emission"
    FAILURE_EMISSION_CANDIDATE = "failure_emission_candidate"
    INTERNAL_EVENT_OR_LOG = "internal_event_or_log"
    COMMENT_REFERENCE = "comment_reference"
    EXECUTABLE_REFERENCE = "executable_reference"


class IdentifierKind(str, Enum):
    """Whether a token is a standard error code or a diagnostic-only identifier."""

    STANDARD_ERROR_CODE = "standard_error_code"
    LEGACY_ERROR_IDENTIFIER = "legacy_error_identifier"
    DIAGNOSTIC_TAG = "diagnostic_tag"


class ErrorCodeOccurrence(NamedTuple):
    code: str
    path: Path
    line: int
    role: OccurrenceRole
    identifier_kind: IdentifierKind
    semantic_fields: tuple[str, ...]
    source: str


def classify_line(
    line: str,
    context: str = "",
    is_structured_failure_boundary: bool = False,
) -> OccurrenceRole:
    """Classify only the literal's local source role; deeper causality is audited later."""
    stripped = line.lstrip()
    if stripped.startswith(("//", "/*", "*")):
        return OccurrenceRole.COMMENT_REFERENCE
    if re.search(r"\b(SealLogEntry|logStore\??\.append|SealLogStore\.append)\s*\(", context):
        return OccurrenceRole.INTERNAL_EVENT_OR_LOG
    if is_structured_failure_boundary:
        return OccurrenceRole.STRUCTURED_FAILURE_EMISSION
    if FAILURE_EMISSION_PATTERN.search(line):
        return OccurrenceRole.FAILURE_EMISSION_CANDIDATE
    if EVENT_MAPPING_PATTERN.search(line):
        return OccurrenceRole.INTERNAL_EVENT_OR_LOG
    return OccurrenceRole.EXECUTABLE_REFERENCE


def classify_identifier(code: str, role: OccurrenceRole) -> IdentifierKind:
    if STANDARD_ERROR_CODE_PATTERN.fullmatch(code):
        return IdentifierKind.STANDARD_ERROR_CODE
    if role in {
        OccurrenceRole.STRUCTURED_FAILURE_EMISSION,
        OccurrenceRole.FAILURE_EMISSION_CANDIDATE,
    }:
        return IdentifierKind.LEGACY_ERROR_IDENTIFIER
    return IdentifierKind.DIAGNOSTIC_TAG


def parenthesized_call_spans(lines: list[str], symbol: str) -> list[tuple[int, int]]:
    """Return zero-based inclusive spans occupied by direct Swift initializer calls."""
    spans: list[tuple[int, int]] = []
    needle = f"{symbol}("
    for start_index, line in enumerate(lines):
        start_offset = line.find(needle)
        if start_offset == -1:
            continue
        depth = 0
        end_index = start_index
        for index in range(start_index, len(lines)):
            fragment = lines[index]
            if index == start_index:
                fragment = fragment[start_offset + len(symbol) :]
            depth += fragment.count("(") - fragment.count(")")
            end_index = index
            if depth <= 0:
                break
        spans.append((start_index, end_index))
    return spans


def direct_failure_contract_fields(lines: list[str]) -> dict[int, tuple[str, ...]]:
    fields_by_line: dict[int, tuple[str, ...]] = {}
    for start, end in parenthesized_call_spans(lines, "ImportFailure"):
        body = "\n".join(lines[start : end + 1])
        fields = tuple(
            field
            for field in STRUCTURED_FAILURE_FIELDS
            if re.search(rf"\b{re.escape(field)}\s*:", body)
        )
        for line_index in range(start, end + 1):
            fields_by_line[line_index] = fields
    return fields_by_line


def scan_file(path: Path) -> list[ErrorCodeOccurrence]:
    occurrences: list[ErrorCodeOccurrence] = []
    lines = path.read_text(encoding="utf-8").splitlines()
    structured_failure_fields = direct_failure_contract_fields(lines)
    for line_number, line in enumerate(lines, start=1):
        context = "\n".join(lines[max(0, line_number - 9) : line_number])
        role = classify_line(
            line,
            context,
            is_structured_failure_boundary=(line_number - 1) in structured_failure_fields,
        )
        for code in ERROR_CODE_PATTERN.findall(line):
            occurrences.append(
                ErrorCodeOccurrence(
                    code=code,
                    path=path,
                    line=line_number,
                    role=role,
                    identifier_kind=classify_identifier(code, role),
                    semantic_fields=structured_failure_fields.get(line_number - 1, ()),
                    source=line.strip(),
                )
            )
    return occurrences


def scan_tree(source_root: Path) -> list[ErrorCodeOccurrence]:
    occurrences: list[ErrorCodeOccurrence] = []
    for path in sorted(source_root.rglob("*.swift")):
        occurrences.extend(scan_file(path))
    return occurrences


def build_inventory(
    occurrences: list[ErrorCodeOccurrence], project_root: Path
) -> dict[str, object]:
    """Build a traceable inventory without asserting unverified user-facing semantics."""
    grouped: dict[str, list[ErrorCodeOccurrence]] = defaultdict(list)
    for occurrence in occurrences:
        grouped[occurrence.code].append(occurrence)

    codes: dict[str, object] = {}
    for code in sorted(grouped):
        code_occurrences = grouped[code]
        role_counts = Counter(item.role.value for item in code_occurrences)
        kind_counts = Counter(item.identifier_kind.value for item in code_occurrences)
        locations: list[dict[str, object]] = []
        for item in code_occurrences:
            try:
                relative_path = item.path.relative_to(project_root).as_posix()
            except ValueError:
                relative_path = item.path.as_posix()
            locations.append(
                {
                    "path": relative_path,
                    "line": item.line,
                    "role": item.role.value,
                    "identifierKind": item.identifier_kind.value,
                    "semanticFields": list(item.semantic_fields),
                    "source": item.source,
                }
            )
        codes[code] = {
            "auditStatus": audit_status(code_occurrences),
            "occurrenceCount": len(code_occurrences),
            "roles": dict(sorted(role_counts.items())),
            "identifierKinds": dict(sorted(kind_counts.items())),
            "locations": locations,
        }

    direct_failures = [
        item
        for item in occurrences
        if item.role == OccurrenceRole.STRUCTURED_FAILURE_EMISSION
    ]
    direct_failures_with_semantics = [
        item for item in direct_failures if item.semantic_fields
    ]

    return {
        "schemaVersion": 1,
        "scope": "Seal/**/*.swift",
        "summary": {
            "uniqueIdentifiers": len(codes),
            "occurrences": len(occurrences),
            "roles": dict(sorted(Counter(item.role.value for item in occurrences).items())),
            "identifierKinds": dict(
                sorted(Counter(item.identifier_kind.value for item in occurrences).items())
            ),
            "structuredFailureContracts": {
                "directOccurrences": len(direct_failures),
                "withExplicitSemantics": len(direct_failures_with_semantics),
                "withoutExplicitSemantics": len(direct_failures) - len(direct_failures_with_semantics),
            },
        },
        "codes": codes,
    }


def audit_status(occurrences: list[ErrorCodeOccurrence]) -> str:
    """Derive evidence status without inventing a user-facing recovery."""
    direct = [
        item
        for item in occurrences
        if item.role == OccurrenceRole.STRUCTURED_FAILURE_EMISSION
    ]
    if direct:
        with_semantics = [item for item in direct if item.semantic_fields]
        if len(with_semantics) == len(direct):
            return "contracted"
        if with_semantics:
            return "mixed"
        return "unreviewed"

    if all(item.identifier_kind == IdentifierKind.DIAGNOSTIC_TAG for item in occurrences):
        return "diagnostic_only"
    return "reference_only"


def write_inventory(project_root: Path, destination: Path) -> dict[str, object]:
    inventory = build_inventory(scan_tree(project_root / "Seal"), project_root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        json.dumps(inventory, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return inventory


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    output = args.output if args.output.is_absolute() else root / args.output
    inventory = write_inventory(root, output)
    summary = inventory["summary"]
    print(
        "Generated inventory: "
        f"{summary['uniqueIdentifiers']} identifiers, {summary['occurrences']} occurrences."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
