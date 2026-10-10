# Seal Error Knowledge Base Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a single, evidence-labelled error catalog that powers Seal diagnostics and can be safely exported to the official help center.

**Architecture:** JSON catalog entries are authoritative. A Python generator validates entries against Swift error-code literals and emits deterministic App/web indexes. Swift loads the bundled index for offline help while existing website deep links retain the code query. The first implementation catalogs audited high-risk codes only; CI prevents cataloged content from drifting and reports uncataloged user-visible codes without pretending coverage.

**Tech Stack:** Swift 6, Swift Testing, Python 3 standard library, GitHub Actions, JSON Schema.

---

### Task 1: Establish schema and catalog validation

**Files:**
- Create: `docs/error-catalog/schema.json`
- Create: `docs/error-catalog/auth.json`
- Create: `Scripts/error_catalog.py`
- Test: `Scripts/tests/test_error_catalog.py`

- [ ] Write failing schema-validation tests.

```python
def test_confirmed_entry_requires_evidence():
    entry = {"code": "SEAL-AUTH-102c", "kind": "failure", "confidence": "confirmed", "summary": "x", "actions": [{"title": "x"}], "source": ["Seal/X.swift"]}
    assert validate_catalog([entry]).errors == ["SEAL-AUTH-102c: confirmed entries require evidence"]

def test_unknown_entry_requires_non_inference():
    entry = {"code": "SEAL-AUTH-999", "kind": "failure", "confidence": "unknown", "summary": "x", "actions": [{"title": "导出日志"}], "source": ["Seal/X.swift"]}
    assert "unknown entries require notEvidenceOf" in validate_catalog([entry]).errors[0]
```

- [ ] Run `python -m unittest Scripts.tests.test_error_catalog -v`; it must fail because the catalog module does not exist.
- [ ] Implement loader/validator with `failure|warning|diagnostic`, `confirmed|conditional|unknown`, required evidence for confirmed entries, and required non-inference text for conditional/unknown entries.
- [ ] Seed only audited `SEAL-AUTH-102c`, `SEAL-AUTH-107`, and `SEAL-SIGN-501`; Apple responses that could also be rate limiting are conditional.
- [ ] Rerun the test, verify it passes, and commit the foundation.

### Task 2: Generate a deterministic help index and enforce coverage

**Files:**
- Modify: `Scripts/error_catalog.py`
- Create: `docs/error-catalog/generated/help-index.json`
- Create: `Scripts/tests/test_error_catalog_generation.py`
- Modify: `Scripts/verify-release-safety.py`

- [ ] Write a failing test that `generate_help_index` sorts entries by code and has no timestamp.
- [ ] Run `python -m unittest Scripts.tests.test_error_catalog_generation -v`; it must fail for missing generator.
- [ ] Scan Swift literals matching `SEAL-[A-Z]+-[0-9]+[a-z]?` and report source, cataloged, and uncataloged sets.
- [ ] Generate UTF-8 JSON with stable `schemaVersion` and sorted keys.
- [ ] Add release-safety checks: catalog code must still exist; generated output must be current; every code passed into `ImportFailure` must have a catalog entry. Non-`ImportFailure` codes only warn until audited.
- [ ] Run `python Scripts/error_catalog.py generate --root .` plus both unit suites; commit generator and guard.

### Task 3: Audit high-risk families and repair false attribution

**Files:**
- Create: `docs/error-catalog/install.json`
- Create: `docs/error-catalog/profile.json`
- Create: `docs/error-catalog/storage.json`
- Create: `docs/error-catalog/self.json`
- Modify: `docs/qa/log-code-index.md`
- Test: `Scripts/tests/test_error_catalog_audited_families.py`

- [ ] Write failing tests that `SEAL-INSTALL-702t` is conditional and explicitly does not prove installation failed, `SEAL-PROFILE-363` is conditional diagnostic rather than terminal failure, and `SEAL-INSTALL-702s` is confirmed only with `ENOSPC` evidence.
- [ ] Run that test suite and verify missing-entry failures.
- [ ] For every entry, trace producer -> catch/wrap -> log -> UI -> recovery before cataloging. Mark ambiguous transport symptoms conditional.
- [ ] If audit proves an `ImportFailure` is wrong, write a focused failing Swift regression test first, repair the producing or conversion layer, add a `DEBUG_LOG.md` record, and verify the owning tests.
- [ ] Regenerate index, run audit tests and `git diff --check`; commit each family independently.

### Task 4: Add offline App help

**Files:**
- Create: `Seal/Core/Diagnostics/ErrorKnowledgeEntry.swift`
- Create: `Seal/Core/Diagnostics/ErrorKnowledgeStore.swift`
- Create: `Seal/Features/Settings/ErrorHelpView.swift`
- Modify: `Seal/Features/Settings/LogViewerView.swift`
- Modify: `Seal/Features/Apps/AppsRootView.swift`
- Modify: `Seal/Features/Apps/AppDetailView.swift`
- Modify: `Seal/Features/Apps/AppSigningSheet.swift`
- Modify: `project.yml`
- Test: `SealTests/Diagnostics/ErrorKnowledgeStoreTests.swift`
- Test: `SealTests/Settings/ErrorHelpViewTests.swift`

- [ ] Write failing Swift tests: a catalogued conditional code exposes its uncertainty; an unknown code offers only log export and website help, never an invented cause.
- [ ] Run focused `xcodebuild test` on macOS CI and verify missing-store compile failure.
- [ ] Bundle the generated JSON resource, decode it once in an actor-safe store, and make missing codes return a conservative unknown help model.
- [ ] Add a screen with code, severity, confidence, summary, evidence, “不能据此判断”, ordered actions, and copy/export diagnostic. Use it from error dialogs and log rows; preserve the website as secondary help.
- [ ] Run focused then complete Swift test suite in CI; commit only after evidence.

### Task 5: Synchronize official help safely

**Files:**
- Modify: `.github/workflows/ios-release.yml`
- Modify: `.github/workflows/ios.yml`
- Modify: `Scripts/verify-release-safety.py`
- Create: `docs/qa/error-help-center-sync.md`

- [ ] Write a failing workflow test requiring a named help-sync step, `continue-on-error: true`, and `help-index.json`.
- [ ] Run it and verify red until a verified ingestion route exists.
- [ ] Upload exactly generated JSON via official help repository/deployment action or a verified endpoint. Retry transient errors, compare returned digest/version, and warn without failing IPA publication if it cannot synchronize.
- [ ] Document manual recovery and SHA-256 verification. Do not assume the existing release-changelog endpoint accepts help content.
- [ ] Run the full `ios.yml` workflow, then push only after complete CI evidence.

## Plan self-review

- Tasks 1–2 establish one source and drift prevention.
- Task 3 uses evidence before fixes, preventing ambiguous symptoms from becoming false root-cause claims.
- Task 4 adds offline help without removing website search.
- Task 5 is gated on a verified help ingest path; existing changelog sync is not treated as evidence of help publishing support.
