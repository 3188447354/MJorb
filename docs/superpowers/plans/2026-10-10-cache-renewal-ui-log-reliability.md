# Cache, Renewal, UI, and Log Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Safely release regenerable signed IPA caches without disabling profile-only renewal, publish certificate readiness immediately after full signing, and make first log export reliable.

**Architecture:** The renewal identity and the signed IPA cache become separate concerns. A pure cleanup policy selects only safe caches; profile-only admission relies on installed identity rather than cache presence. Log export returns an awaited concrete file URL, while onboarding receives a geometry-only refinement.

**Tech Stack:** Swift 6, SwiftUI, Core Data, XCTest / Swift Testing, actors.

---

### Task 1: Signed IPA cache policy

**Files:**
- Create: `Seal/Core/Maintenance/SignedIPACacheCleanupPolicy.swift`
- Create: `SealTests/Maintenance/SignedIPACacheCleanupPolicyTests.swift`
- Modify: `Seal/Core/Apps/AppRecord.swift`

- [ ] Add failing pure-policy tests: stable confirmed cache is reclaimable; `.awaitingVerification`, `.installFailed`, a pending snapshot, and a pending update source are protected.
- [ ] Run the focused test and verify it fails because the policy does not exist.
- [ ] Implement `SignedIPACacheCleanupPolicy.decision(for:)`; it must be pure and return `.reclaimable` or `.protected(reason)`.
- [ ] Add `AppRecord.clearSignedIPACacheMetadata()`; it may clear path/hash/size/date only and must retain installation state and renewal identity.
- [ ] Re-run focused tests and commit `feat: classify signed IPA cache cleanup candidates`.

### Task 2: Profile-only eligibility survives cache deletion

**Files:**
- Modify: `Seal/Core/Renewal/ProfileOnlyRenewalPolicy.swift`
- Modify: `Seal/Core/Signing/SigningCoordinator.swift`
- Modify: `SealTests/Renewal/ProfileOnlyRenewalPolicyTests.swift`

- [ ] Add a failing test showing that a complete installed third-party identity with no signed-cache metadata remains profile-only eligible.
- [ ] Verify the old policy fails it with `.missingInstalledArtifact`.
- [ ] Remove cache-file and cache-status requirements from profile-only admission while retaining account, team, certificate, device, mapping, target, private-key, and pending-update checks.
- [ ] Resolve `Original.ipa` only for Portal slow-path parsing; stored complete target entitlements take the fast path without opening it.
- [ ] Re-run focused renewal tests and commit `fix: preserve profile-only renewal after cache cleanup`.

### Task 3: Storage maintenance and button visibility

**Files:**
- Modify: `Seal/Features/Settings/SettingsViewModel.swift`
- Modify: `Seal/Infrastructure/Storage/AppFileStore.swift`
- Modify: `Seal/Features/Settings/StorageMaintenanceView.swift`
- Modify: `SealTests/Settings/StorageMaintenanceSummaryTests.swift`

- [ ] Add failing preview tests proving protected cache is omitted and a zero-candidate category has no action.
- [ ] Build a candidate preview with count and bytes before deletion.
- [ ] Delete only preview candidates with a cache-only file-store method; update cache metadata only after file deletion succeeds.
- [ ] Stop `removeSignedIPA` from deleting `Exports/<appID>`; count and clear exports via the temporary/export category.
- [ ] Rename the action to “释放可重建安装缓存”; show it only for positive candidate count and bytes. Hide other empty maintenance actions too.
- [ ] Re-run focused storage tests and commit `fix: release only safe signed IPA caches`.

### Task 4: Immediate certificate-state publication

**Files:**
- Modify: `Seal/Features/Apps/AppsViewModel.swift`
- Create or modify: `SealTests/Apps/AppsViewModelCertificateAvailabilityTests.swift`

- [ ] Add a failing test: a successful full resign changes an already-open action drawer’s availability from `.needsFullResign` to `.ready` without `load()`.
- [ ] Trace every successful signing completion into one internal state-publication seam.
- [ ] Replace the observed app record first, publish `.ready` from the known successful private-key fact, then refresh Keychain-derived state without overriding that fact on a transient empty read.
- [ ] Run focused tests and commit `fix: publish certificate readiness after signing`.

### Task 5: Deterministic log export

**Files:**
- Modify: `Seal/Infrastructure/Diagnostics/SealLogStore.swift`
- Modify: `Seal/Features/Settings/LogViewerView.swift`
- Modify: `Seal/Application/AppContainer.swift`
- Create or modify: `SealTests/Diagnostics/SealLogStoreTests.swift`

- [ ] Add a failing test that the first `materializeExport()` call returns an existing readable `Documents/Seal-log.txt`.
- [ ] Implement `SealLogStore.materializeExport() throws -> URL`, which atomically writes redacted header-only-or-populated text and returns only after success.
- [ ] Replace notification-plus-800ms-sleep export with the awaited export contract; report a write error instead of presenting an empty file sheet.
- [ ] Run diagnostics tests and verify no timed sleep remains in `exportLogs()`.
- [ ] Commit `fix: make first log export deterministic`.

### Task 6: Onboarding geometry and behavior guard

**Files:**
- Modify: `Seal/Features/Settings/AgreementOnboardingView.swift`
- Modify: `SealTests/Settings/AgreementOnboardingLayoutTests.swift`
- Modify: `SealUITests/AgreementGateUITests.swift`

- [ ] Add a failing layout test for positioning the brand group relative to the visible region above the initial sheet detent.
- [ ] Replace the fixed top spacer with that geometry; retain the current icon asset, links, NavigationStack, non-dismissible gate, decline alert, and drawer restoration behavior.
- [ ] Run layout and agreement UI tests; acceptance must reach root tabs and both agreement links must remain tappable.
- [ ] Commit `refine: balance agreement onboarding layout`.

### Task 7: Final validation

**Files:**
- Modify: `DEBUG_LOG.md`
- Modify: `docs/superpowers/specs/2026-10-10-signed-ipa-cache-and-renewal-identity.md`

- [ ] Record both root causes: cache identity conflation and notification-plus-sleep export.
- [ ] Run `git diff --check`; preserve unrelated untracked files.
- [ ] Push once and monitor the complete iOS workflow only; do not dispatch Fast IPA.
- [ ] After green CI, verify IPA SHA-256 and place a non-overwriting build-specific IPA in `D:\A数据中心\OneDrive\Desktop\Seal IPA`.
