# State Reconciliation and Maintenance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make onboarding, signing, certificate revocation, and storage maintenance converge immediately on real state.

**Architecture:** Keep the onboarding gate in `SealApp`, but present its consent surface as a native non-dismissible sheet. Centralize post-operation reconciliation in each owning view model: signing refreshes app/keychain-derived state, certificate mutations update the inventory cache and dismissal state, and storage cleanup updates both disk and persisted artifact metadata.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Core Data, AppFileStore.

---

### Task 1: Native agreement sheet

**Files:**
- Modify: `Seal/Features/Settings/AgreementOnboardingView.swift`
- Test: `SealTests/Settings/AgreementVersionTests.swift`

- [x] Existing agreement-gate tests cover the accepted/non-accepted launch parameter behavior; local Xcode execution is unavailable on this Windows host.
- [x] Replace the fixed `consentSheet(height:)` overlay with a presented SwiftUI sheet using a short detent plus `.large`, a visible system drag indicator, and `.interactiveDismissDisabled()`.
- [x] Anchor `brandSection` at the top of the background host, preserving Reduce Motion behavior and Dynamic Type-safe consent controls.
- [ ] Run the agreement tests and build the test target.

### Task 2: Post-signing app-state reconciliation

**Files:**
- Modify: `Seal/Features/Apps/AppsViewModel.swift`
- Modify: `Seal/Features/Apps/AppSigningSheet.swift` only if a live-state dependency is missing
- Test: `SealTests/Apps/AppsViewModelTests.swift` or the closest existing signing/view-model test file

- [x] Existing policy tests cover the availability derivation; the view-model integration is verified in full CI because local Xcode execution is unavailable.
- [x] Add one `AppsViewModel` reconciliation method that reloads account secrets and recomputes certificate availability from the current app records.
- [x] Call that method on every successful signing/renewal persistence exit before the operation sheet can return to configuration.
- [ ] Run the focused test and the existing signing regression tests.

### Task 3: Certificate inventory convergence

**Files:**
- Modify: `Seal/Features/Settings/SettingsViewModel.swift`
- Test: `SealTests/Settings/SettingsViewModelTests.swift` or a new focused inventory test

- [x] Add an inventory visibility regression test for a dismissed serial returned by a later portal response.
- [x] Apply dismissal filtering to every inventory publication path, including complete refresh and disk-cache restore.
- [x] Preserve the existing failed-revocation behavior: it never writes a persistent dismissal.
- [ ] Run the focused inventory tests.

### Task 4: Reclaim signed-package storage safely

**Files:**
- Modify: `Seal/Core/Apps/AppRecord.swift`
- Modify: `Seal/Features/Settings/SettingsViewModel.swift`
- Modify: `Seal/Features/Settings/StorageMaintenanceView.swift`
- Test: `SealTests/Storage/AppFileStoreTests.swift`
- Test: `SealTests/Apps/AppRecordTests.swift`

- [x] Add a record regression test asserting that clearing a signed artifact keeps the original IPA but removes all signed-artifact metadata.
- [x] Add a focused record mutation for signed-package cleanup.
- [x] Implement the view-model operation under the maintenance lease: fetch records, remove each signed package, persist the corresponding record mutation, refresh measured storage, and report actual freed bytes.
- [x] Add a confirmed destructive action to the storage screen with precise copy explaining that reinstall will require re-signing.
- [ ] Run focused storage and record tests.

### Task 5: Regression sweep and delivery

**Files:**
- Modify only any files required by failing focused regressions.

- [ ] Run formatting/diff checks and targeted Swift tests.
- [ ] Run the complete iOS GitHub Actions workflow only; do not dispatch the Fast IPA workflow manually.
- [ ] On failure, use the exact job log to add a red regression test before the root-cause fix.
- [ ] When the complete workflow passes, download its IPA artifact, verify SHA-256, and place it in `D:\A数据中心\OneDrive\Desktop\Seal IPA`.
