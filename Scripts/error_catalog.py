#!/usr/bin/env python3
"""Validate and export Seal's evidence-labelled error knowledge catalog."""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


ALLOWED_KINDS = {"failure", "warning", "diagnostic"}
ALLOWED_CONFIDENCE = {"confirmed", "conditional", "unknown"}
REQUIRED_FIELDS = {"code", "kind", "confidence", "summary", "actions", "source"}


@dataclass(frozen=True)
class ValidationResult:
    errors: list[str]


def validate_catalog(entries: Iterable[dict[str, Any]]) -> ValidationResult:
    errors: list[str] = []
    seen_codes: set[str] = set()
    for entry in entries:
        code = str(entry.get("code", "<missing code>"))
        missing = sorted(REQUIRED_FIELDS - entry.keys())
        if missing:
            errors.append(f"{code}: missing required fields: {', '.join(missing)}")
            continue
        if code in seen_codes:
            errors.append(f"{code}: duplicate code")
        seen_codes.add(code)
        if entry["kind"] not in ALLOWED_KINDS:
            errors.append(f"{code}: invalid kind")
        if entry["confidence"] not in ALLOWED_CONFIDENCE:
            errors.append(f"{code}: invalid confidence")
        if not isinstance(entry["summary"], str) or not entry["summary"].strip():
            errors.append(f"{code}: summary must not be empty")
        if not isinstance(entry["actions"], list) or not entry["actions"]:
            errors.append(f"{code}: actions must not be empty")
        elif any(not isinstance(action.get("title"), str) or not action["title"].strip() for action in entry["actions"]):
            errors.append(f"{code}: every action requires a title")
        if not isinstance(entry["source"], list) or not entry["source"]:
            errors.append(f"{code}: source must not be empty")
        if entry["confidence"] == "confirmed" and not entry.get("evidence"):
            errors.append(f"{code}: confirmed entries require evidence")
        if entry["confidence"] in {"conditional", "unknown"} and not entry.get("notEvidenceOf"):
            errors.append(f"{code}: {entry['confidence']} entries require notEvidenceOf")
    return ValidationResult(errors)


def load_catalog(catalog_directory: Path) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    for path in sorted(catalog_directory.glob("*.json")):
        if path.name == "schema.json":
            continue
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict) or not isinstance(payload.get("entries"), list):
            raise ValueError(f"{path}: expected an object with an entries array")
        entries.extend(payload["entries"])
    return entries


def generate_help_index(entries: Iterable[dict[str, Any]]) -> dict[str, Any]:
    """Return a stable payload for the website help catalog."""
    ordered_entries = sorted(entries, key=lambda entry: entry["code"])
    return {
        "schemaVersion": 1,
        "entries": ordered_entries,
    }


def source_error_codes(root: Path) -> set[str]:
    pattern = re.compile(r"SEAL-[A-Z]+-[0-9]+[a-z]?")
    codes: set[str] = set()
    for path in (root / "Seal").rglob("*.swift"):
        codes.update(pattern.findall(path.read_text(encoding="utf-8")))
    return codes


def write_help_index(root: Path, entries: list[dict[str, Any]]) -> Path:
    destination = root / "docs" / "error-catalog" / "generated" / "help-index.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(
        generate_help_index(entries),
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    ) + "\n"
    destination.write_text(payload, encoding="utf-8")
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("validate", "generate", "report"))
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args()
    entries = load_catalog(args.root / "docs" / "error-catalog")
    result = validate_catalog(entries)
    if result.errors:
        for error in result.errors:
            print(f"ERROR: {error}")
        return 1
    if args.command == "generate":
        destination = write_help_index(args.root, entries)
        print(f"Generated {destination.relative_to(args.root)} with {len(entries)} entries.")
        return 0
    if args.command == "report":
        catalog_codes = {entry["code"] for entry in entries}
        source_codes = source_error_codes(args.root)
        uncataloged = sorted(source_codes - catalog_codes)
        print(f"Cataloged codes: {len(catalog_codes)}")
        print(f"Source codes: {len(source_codes)}")
        print(f"Uncataloged source codes: {len(uncataloged)}")
        for code in uncataloged:
            print(code)
        return 0
    print(f"Validated {len(entries)} error catalog entries.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
