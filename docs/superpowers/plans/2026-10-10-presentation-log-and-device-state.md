# Presentation, Log, and Device State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove competing drawers, export only real log files, atomically refresh Seal's certificate state, and make agreement detents deterministic.

**Architecture:** Keep signing state in `AppsViewModel`; use pure policies at UI seams. A log share sheet is driven by one verified document route. Self-record reload publishes records and certificate availability together.

**Tech Stack:** Swift 6, SwiftUI, XCTest/Swift Testing, `Scripts/ci-test.sh`.

---

## Files

- Create `Seal/Core/Renewal/PresentationRoutePolicy.swift` and `SealTests/Renewal/PresentationRoutePolicyTests.swift` for exclusive sheet-route decisions.
- Create `Seal/Features/Settings/LogExportDocument.swift` for the verified share URL route.
- Create `Seal/Core/Apps/SelfRecordAvailabilityPolicy.swift` and `SealTests/Apps/SelfRecordAvailabilityPolicyTests.swift` for atomic-self-record publish invariants.
- Modify `AppsRootView.swift`, `AppsViewModel.swift`, `LogViewerView.swift`, `AgreementOnboardingView.swift`, `AgreementOnboardingPresentationState.swift`, `SealLogStoreTests.swift`, `AgreementOnboardingLayoutTests.swift`, `DEBUG_LOG.md`, and `docs/knowledge/PITFALLS.md`.

### Task 1: Exclusive operation sheets

**Files:** Create `Seal/Core/Renewal/PresentationRoutePolicy.swift`; create `SealTests/Renewal/PresentationRoutePolicyTests.swift`; modify `Seal/Features/Apps/AppsRootView.swift`.

- [ ] Write this failing test:

```swift
@Test func startingOperationClearsCompetingRoutes() {
    let route = PresentationRoutePolicy.beginOperation(installedActionRequested: true, detailRequested: true)
    #expect(route.installedActionRequested == false)
    #expect(route.detailRequested == false)
}
```

- [ ] Run `bash Scripts/ci-test.sh -only-testing:SealTests/PresentationRoutePolicyTests`; expect a compile failure because the policy is absent.
- [ ] Add `PresentationRouteState(installedActionRequested:detailRequested:)` and `PresentationRoutePolicy.beginOperation`; it returns both flags false. Add `shouldPresentInstalledAction(operationIsPresented:batchResultIsPresented:installedActionRequested:)`, true only when the first two inputs are false and the third true.
- [ ] In `AppsRootView`, clear `installedActionApp` and `detailApp` through one helper before `beginRenewalDirectly`, before a batch-result sheet, and before finishing a single operation. Remove the 250 ms presentation delay as a correctness mechanism.
- [ ] Run `bash Scripts/ci-test.sh -only-testing:SealTests/PresentationRoutePolicyTests -only-testing:SealTests/PendingBatchResultPayloadTests`; expect PASS.
- [ ] Commit: `git add Seal/Core/Renewal/PresentationRoutePolicy.swift Seal/Features/Apps/AppsRootView.swift SealTests/Renewal/PresentationRoutePolicyTests.swift && git commit -m "fix: prevent competing app operation drawers"`.

### Task 2: Real-file-only log export

**Files:** Create `Seal/Features/Settings/LogExportDocument.swift`; modify `Seal/Features/Settings/LogViewerView.swift` and `SealTests/Diagnostics/SealLogStoreTests.swift`.

- [ ] Write this failing test:

```swift
@Test func exportDocumentRejectsMissingFile() {
    #expect(LogExportDocument(url: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)) == nil)
}
```

- [ ] Run `bash Scripts/ci-test.sh -only-testing:SealTests/SealLogStoreTests`; expect a compile failure because `LogExportDocument` is absent.
- [ ] Implement `LogExportDocument: Identifiable` with `let url: URL`, `var id: URL { url }`, and a failable initializer that checks `FileManager.default.fileExists(atPath:)`.
- [ ] Replace `isExporting` plus `exportURL` with `@State private var exportDocument: LogExportDocument?`; after `materializeLogExport()` returns, set that one value. Present `.sheet(item: $exportDocument)` and remove the empty `日志文件不存在` fallback. If the document cannot be constructed, show `SEAL-LOG-002`.
- [ ] Run `bash Scripts/ci-test.sh -only-testing:SealTests/SealLogStoreTests`; expect PASS including first-export readability.
- [ ] Commit: `git add Seal/Features/Settings/LogExportDocument.swift Seal/Features/Settings/LogViewerView.swift SealTests/Diagnostics/SealLogStoreTests.swift && git commit -m "fix: present only materialized log exports"`.

### Task 3: Atomic self-record certificate state

**Files:** Create `Seal/Core/Apps/SelfRecordAvailabilityPolicy.swift`; create `SealTests/Apps/SelfRecordAvailabilityPolicyTests.swift`; modify `Seal/Features/Apps/AppsViewModel.swift` and `Seal/Features/Apps/AppsRootView.swift`.

- [ ] Write this failing test:

```swift
@Test func selfRecordSnapshotRequiresRecordsAndSecrets() {
    #expect(SelfRecordAvailabilityPolicy.shouldPublish(recordsLoaded: true, secretsLoaded: true))
    #expect(SelfRecordAvailabilityPolicy.shouldPublish(recordsLoaded: true, secretsLoaded: false) == false)
}
```

- [ ] Run `bash Scripts/ci-test.sh -only-testing:SealTests/SelfRecordAvailabilityPolicyTests`; expect a compile failure because the policy is absent.
- [ ] Implement `SelfRecordAvailabilityPolicy.shouldPublish(recordsLoaded:secretsLoaded:) -> Bool` as logical AND. Add `reloadSelfRecordSnapshot()` in `AppsViewModel`: fetch records, accounts, and Keychain secrets first, then publish `apps`, `accounts`, `accountSecrets`, emails, and `refreshCertAvailability()` on the main actor together.
- [ ] Change the `.sealSelfRecordUpdated` receiver to call `reloadSelfRecordSnapshot()`, retaining progressive `load()` only for ordinary list loads.
- [ ] Run `bash Scripts/ci-test.sh -only-testing:SealTests/SelfRecordAvailabilityPolicyTests -only-testing:SealTests/ProfileOnlyRenewalPolicyTests`; expect PASS.
- [ ] Commit: `git add Seal/Core/Apps/SelfRecordAvailabilityPolicy.swift Seal/Features/Apps/AppsViewModel.swift Seal/Features/Apps/AppsRootView.swift SealTests/Apps/SelfRecordAvailabilityPolicyTests.swift && git commit -m "fix: refresh Seal certificate state atomically"`.

### Task 4: Deterministic agreement detents

**Files:** Modify `Seal/Features/Settings/AgreementOnboardingPresentationState.swift`, `Seal/Features/Settings/AgreementOnboardingView.swift`, and `SealTests/Settings/AgreementOnboardingLayoutTests.swift`.

- [ ] Write tests that call `openPolicy()` and expect `.reading`, then `closePolicy()` and expect `.welcome`.
- [ ] Run `bash Scripts/ci-test.sh -only-testing:SealTests/AgreementOnboardingLayoutTests`; expect failure because the transition API is absent.
- [ ] Add `DrawerMode.welcome` and `.reading`. Bind the outer sheet's selected detent to this state: welcome is the compact fraction only; opening either policy selects `.large`; returning selects compact. Remove `Text("为你的应用，保持可用。")` and hide the welcome drag indicator.
- [ ] Run `bash Scripts/ci-test.sh -only-testing:SealTests/AgreementOnboardingLayoutTests`; expect PASS.
- [ ] Commit: `git add Seal/Features/Settings/AgreementOnboardingPresentationState.swift Seal/Features/Settings/AgreementOnboardingView.swift SealTests/Settings/AgreementOnboardingLayoutTests.swift && git commit -m "fix: restore compact agreement drawer after reading"`.

### Task 5: Safety record and verification

**Files:** Modify `DEBUG_LOG.md` and `docs/knowledge/PITFALLS.md`.

- [ ] Record that automatic uninstall removal only follows a successful positive-control device query; unavailable Wi-Fi, LocalDevVPN, USB pairing, or device service retains records.
- [ ] Run:

```bash
bash Scripts/ci-test.sh -only-testing:SealTests/PresentationRoutePolicyTests -only-testing:SealTests/PendingBatchResultPayloadTests -only-testing:SealTests/SealLogStoreTests -only-testing:SealTests/SelfRecordAvailabilityPolicyTests -only-testing:SealTests/AgreementOnboardingLayoutTests
```

Expected: PASS.

- [ ] Run `git diff --check` and `git status --short`; keep pre-existing untracked artifacts untouched.
- [ ] Commit docs, push the branch, then use the complete iOS CI workflow for compilation verification.
