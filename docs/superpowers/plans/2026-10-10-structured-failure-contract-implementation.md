# Seal Structured Failure Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace prefix/string-based recovery and the old Error Help system with a source-classified, auditable failure contract that provides one truthful action in every Seal workflow.

**Architecture:** `ImportFailure` remains the compatibility envelope but gains immutable semantics. `FailureClassifier` is the only boundary that translates raw errors to user action; view models transmit the result and `FailureActionPresenter` renders it. A catalog registers stable codes/actions, while diagnostics are redacted and correlated by a per-failure ID.

**Tech Stack:** Swift 6, SwiftUI, Foundation, Swift Testing, xcodebuild, GitHub Actions.

---

## Execution environment gate

This checkout intentionally contains `project.yml` rather than a checked-in `.xcodeproj`, and the current Windows host has no `xcodebuild`. Before every command below, run it on a macOS runner after generating the project with the repository's existing CI setup command. On this Windows host, source inspection, patch creation, static scans and `git diff --check` are valid; an iOS build/test result is not available and must not be claimed. Do not push merely to obtain validation unless the user explicitly requests a CI run.

Mac preflight:

```bash
xcodegen generate
xcodebuild -list -project Seal.xcodeproj
```

Expected: the generated `Seal.xcodeproj` lists the app scheme and the test scheme used by the workflow.

---

## Locked file structure

- Create: `Seal/Core/Import/FailureContract.swift` — condition, action, operation, origin, retry, catalog.
- Create: `Seal/Core/Import/FailureClassifier.swift` — sole raw-error classification boundary.
- Create: `Seal/Core/Diagnostics/FailureDiagnosticRecord.swift` — redacted structured diagnostic data.
- Modify: `Seal/Core/Import/ImportFailure.swift` — legacy-compatible failure envelope with semantic metadata.
- Modify: `Seal/Core/Accounts/AppleServiceFailurePolicy.swift`, `Seal/Infrastructure/Signing/ApplePortalSigningService.swift` (contains `ApplePortalSigningFailure`), `Seal/Core/Renewal/RenewalCoordinator.swift`, `Seal/Core/Signing/SigningCoordinator.swift`, `Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`.
- Create: `Seal/Features/Shared/FailureActionPresenter.swift`.
- Modify: `Seal/Features/Apps/AppsViewModel.swift`, `Seal/Features/Apps/AppsRootView.swift`, `Seal/Features/Apps/AppDetailView.swift`, `Seal/Features/Apps/AppSigningSheet.swift`, `Seal/Features/Settings/SettingsViewModel.swift`, `Seal/Features/Settings/LogViewerView.swift`, `Seal/Features/Settings/InstallFailureSettingsRoute.swift`, `Seal/Features/Settings/SettingsRootView.swift`.
- Delete: `Seal/Features/Settings/ErrorHelpView.swift`, `Seal/Core/Diagnostics/ErrorKnowledgeStore.swift`, `Seal/Resources/ErrorHelp/help-index.json`, `SealTests/Diagnostics/ErrorKnowledgeStoreTests.swift`.
- Create/modify focused tests under `SealTests/Import`, `SealTests/Diagnostics`, `SealTests/Features`, `SealTests/Accounts`, `SealTests/Renewal`, `SealTests/Installation`, `SealTests/Settings`.
- Modify: `Scripts/error_catalog.py`, relevant `.github/workflows`, `DEBUG_LOG.md`, `docs/upstream-alignment.md`.

### Task 1: Add the backward-compatible failure contract

**Files:**
- Create: `Seal/Core/Import/FailureContract.swift`
- Modify: `Seal/Core/Import/ImportFailure.swift`
- Test: `SealTests/Import/FailureContractTests.swift`

- [ ] **Step 1: Write failing semantic tests**

```swift
@Test
func legacyFailureGetsSafeUnknownSemantics() {
    let failure = ImportFailure(title: "签名失败", reason: "未知", recovery: "复制诊断", code: "SEAL-SIGN-500")
    #expect(failure.condition == .unexpected)
    #expect(failure.action == .copyDiagnostics)
    #expect(failure.route == nil)
    #expect(failure.retryDisposition == .none)
}

@Test
func profileOnlyMissingAppIDRequiresFullResign() {
    let failure = ImportFailure.profileOnlyAppIDMissing(operation: .renew)
    #expect(failure.code == "SEAL-PROFILE-337")
    #expect(failure.condition == .fullResignRequired)
    #expect(failure.action == .fullResign)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -project Seal.xcodeproj -scheme Seal -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:SealTests/FailureContractTests`

Expected: compiler reports missing semantic types/API.

- [ ] **Step 3: Implement minimal domain types**

Create:
```swift
enum FailureCondition: String, Codable, Sendable { case appleServiceUnavailable, appleRateLimited, credentialsRejected, verificationCodeRejected, fullResignRequired, pairingRequired, deviceTrustRequired, tunnelUnavailable, deviceStorageFull, installationStillRunning, signedArtifactInvalid, localStorageWriteFailed, logServiceUnavailable, logExportFileInvalid, unexpected }
enum FailureAction: String, Codable, Sendable { case retry, waitThenRetry, reauthenticateAccount, enterNewVerificationCode, fullResign, repairPairing, trustDevice, openLocalDevVPN, freeDeviceStorage, checkInstallationResult, reinstallFromSignedArtifact, reimportIPA, restartSeal, copyDiagnostics }
enum FailureOperation: String, Codable, Sendable { case sign, renew, batchRenew, install, importIPA, exportLog }
enum FailureOrigin: String, Codable, Sendable { case authentication, applePortal, provisioning, signing, deviceChannel, installer, fileStore, logStore, unknown }
enum FailureRetryDisposition: String, Codable, Sendable { case none, automatic, manual, waitForInFlightWork }
```

Extend `ImportFailure` with these fields plus `diagnosticID`; keep the existing four-field initializer source compatible through default values. Add deterministic factories instead of inspecting code strings.

- [ ] **Step 4: Run test and commit**

Run: command from Step 2. Expected: PASS.

```powershell
git add Seal/Core/Import/FailureContract.swift Seal/Core/Import/ImportFailure.swift SealTests/Import/FailureContractTests.swift
git commit -m "feat: add structured failure contract"
```

### Task 2: Establish one classifier and redacted diagnostics

**Files:**
- Create: `Seal/Core/Import/FailureClassifier.swift`
- Create: `Seal/Core/Diagnostics/FailureDiagnosticRecord.swift`
- Test: `SealTests/Import/FailureClassifierTests.swift`
- Test: `SealTests/Diagnostics/FailureDiagnosticRecordTests.swift`

- [ ] **Step 1: Write failing tests for the confirmed timeout incident**

```swift
@Test
func appleTimeoutHasTheSameActionInAllSigningFlows() {
    for operation in [FailureOperation.sign, .renew, .batchRenew] {
        let failure = FailureClassifier.classify(URLError(.timedOut), operation: operation, origin: .applePortal)
        #expect(failure.condition == .appleServiceUnavailable)
        #expect(failure.action == .retry)
        #expect(failure.retryDisposition == .manual)
        #expect(failure.code == "SEAL-NET-102")
    }
}

@Test
func diagnosticsRedactEmailAndRequestURL() {
    let error = NSError(domain: NSURLErrorDomain, code: -1001, userInfo: [
        NSURLErrorFailingURLStringErrorKey: "https://developerservices2.apple.com/a?appleId=user@example.com"
    ])
    let failure = FailureClassifier.classify(error, operation: .sign, origin: .applePortal)
    #expect(FailureDiagnosticRecord(failure: failure, underlying: error).redactedCause.contains("user@example.com") == false)
}
```

- [ ] **Step 2: Run focused tests**

Run: `xcodebuild test -project Seal.xcodeproj -scheme Seal -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:SealTests/FailureClassifierTests -only-testing:SealTests/FailureDiagnosticRecordTests`

Expected: FAIL because classifier/record do not exist.

- [ ] **Step 3: Implement and lock precedence**

Implement `FailureClassifier.classify(_:operation:origin:)`. Precedence must be: existing deterministic `ImportFailure` → profile/certificate/App ID state → `InstallChannelDiagnostic` → `AppleServiceFailurePolicy` → local file/log error → `.unexpected`. Generate a UUID diagnostic ID only when absent. Use `LogPrivacyRedactor` for all recorded cause text.

- [ ] **Step 4: Verify and commit**

Run: command from Step 2. Expected: PASS; timeout never falls to `SEAL-SIGN-500`.

```powershell
git add Seal/Core/Import/FailureClassifier.swift Seal/Core/Diagnostics/FailureDiagnosticRecord.swift SealTests/Import/FailureClassifierTests.swift SealTests/Diagnostics/FailureDiagnosticRecordTests.swift
git commit -m "feat: classify failures at operation boundaries"
```

### Task 3: Correct Apple, profile, signing and renewal propagation

**Files:**
- Modify: `Seal/Core/Accounts/AppleServiceFailurePolicy.swift`
- Modify: `Seal/Infrastructure/Signing/ApplePortalSigningService.swift`
- Modify: `Seal/Features/Apps/AppsViewModel.swift`
- Modify: `Seal/Core/Renewal/RenewalCoordinator.swift`
- Modify: `Seal/Core/Signing/SigningCoordinator.swift`
- Test: `SealTests/Accounts/AppleServiceFailurePolicyTests.swift`
- Test: `SealTests/Signing/ApplePortalSigningFailureTests.swift`
- Test: `SealTests/Renewal/RenewalCoordinatorLogTests.swift`
- Create: `SealTests/Features/AppsViewModelFailureTests.swift`

- [ ] **Step 1: Add cross-entry regressions**

```swift
@Test
func singleSignAndBatchRenewalKeepTheSameTimeoutAction() {
    let error = URLError(.timedOut)
    let single = AppsViewModel.signingFailure(for: error, operation: .sign)
    let batch = RenewalCoordinator.normalizeForTesting(error, operation: .batchRenew)
    #expect(single.condition == batch.condition)
    #expect(single.action == batch.action)
    #expect(single.code == batch.code)
}

@Test
func profileOnlyMissingAppIDDoesNotRequestAppleReauthentication() {
    let failure = ApplePortalSigningFailure.profileOnlyAppIDMissing()
    #expect(failure.action == .fullResign)
    #expect(AppleServiceFailurePolicy.shouldRequireReverification(failure) == false)
}
```

- [ ] **Step 2: Run focused tests**

Run: `xcodebuild test -project Seal.xcodeproj -scheme Seal -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:SealTests/AppleServiceFailurePolicyTests -only-testing:SealTests/ApplePortalSigningFailureTests -only-testing:SealTests/RenewalCoordinatorLogTests -only-testing:SealTests/AppsViewModelFailureTests`

Expected: FAIL because current final catches rewrite to `SEAL-SIGN-500`, `SEAL-RENEW-500`, or generic account unavailable.

- [ ] **Step 3: Change only boundary behavior**

Attach semantics at Apple/profile factories, keep existing stable codes, and remove “梯子” copy. Replace `unexpectedSigningFailure`, `signingFailure(for:)`, `RenewalCoordinator.normalize`, and `renewalGuidance(for:)` rewriting with classifier pass-through. Retain retries, but base them on `retryDisposition`, never code prefixes. Append a redacted diagnostic only for the final failure.

- [ ] **Step 4: Verify, document, and commit**

Run: command from Step 2 plus `-only-testing:SealTests/SigningCoordinatorSignedArtifactTests`. Expected: PASS.

Append tested source facts to `docs/upstream-alignment.md` and `DEBUG_LOG.md`.

```powershell
git add Seal/Core/Accounts/AppleServiceFailurePolicy.swift Seal/Infrastructure/Signing/ApplePortalSigningService.swift Seal/Features/Apps/AppsViewModel.swift Seal/Core/Renewal/RenewalCoordinator.swift Seal/Core/Signing/SigningCoordinator.swift SealTests docs/upstream-alignment.md DEBUG_LOG.md
git commit -m "fix: preserve classified signing and renewal failures"
```

### Task 4: Preserve independent installation/device actions

**Files:**
- Modify: `Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`
- Modify: `Seal/Core/Installation/InstallChannelDiagnostic.swift`
- Modify: `Seal/Features/Settings/InstallFailureSettingsRoute.swift`
- Test: `SealTests/Installation/InstallChannelDiagnosticClassificationTests.swift`
- Test: `SealTests/Settings/InstallFailureSettingsRouteTests.swift`

- [ ] **Step 1: Write a distinct-action matrix test**

```swift
@Test(arguments: [
    ("SEAL-INSTALL-704", FailureCondition.deviceTrustRequired, FailureAction.trustDevice, nil),
    ("SEAL-INSTALL-710", FailureCondition.tunnelUnavailable, FailureAction.openLocalDevVPN, SettingsRoute.localDevVPN),
    ("SEAL-INSTALL-702s", FailureCondition.deviceStorageFull, FailureAction.freeDeviceStorage, nil),
    ("SEAL-INSTALL-702t", FailureCondition.installationStillRunning, FailureAction.checkInstallationResult, nil)
])
func installDiagnosticsStayDistinct(code: String, condition: FailureCondition, action: FailureAction, route: SettingsRoute?) {
    let failure = InstallFailureActionPolicy.failure(for: code, operation: .install)
    #expect(failure.condition == condition)
    #expect(failure.action == action)
    #expect(failure.route == route)
}
```

- [ ] **Step 2: Run focused installation tests**

Run: `xcodebuild test -project Seal.xcodeproj -scheme Seal -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:SealTests/InstallChannelDiagnosticClassificationTests -only-testing:SealTests/InstallFailureSettingsRouteTests`

Expected: FAIL until route reads metadata.

- [ ] **Step 3: Map diagnostics to metadata**

Keep `MinimuxerInstallChannel`'s concrete diagnostics. Replace `route(forCode:)` with `route(for failure: ImportFailure)`; delete prefix routing and duplicate code sets after the domain factory owns each mapping. Do not send storage, signed artifact, timeout, or trust errors to LocalDevVPN.

- [ ] **Step 4: Verify and commit**

Run: command from Step 2. Expected: PASS.

```powershell
git add Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift Seal/Core/Installation/InstallChannelDiagnostic.swift Seal/Features/Settings/InstallFailureSettingsRoute.swift SealTests/Installation/InstallChannelDiagnosticClassificationTests.swift SealTests/Settings/InstallFailureSettingsRouteTests.swift
git commit -m "fix: route installation recovery by failure action"
```

### Task 5: Make log export a real, separately diagnosable feature

**Files:**
- Modify: `Seal/Infrastructure/Diagnostics/SealLogStore.swift`
- Modify: `Seal/Features/Settings/SettingsViewModel.swift`
- Modify: `Seal/Features/Settings/LogViewerView.swift`
- Test: `SealTests/Diagnostics/SealLogStoreTests.swift`
- Create: `SealTests/Settings/LogExportFailureTests.swift`

- [ ] **Step 1: Write failing export tests**

```swift
@Test
func emptyLogsExportAsARealUTF8File() async throws {
    let store = try SealLogStore.temporaryForTesting()
    let url = try await store.materializeExport()
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(try String(contentsOf: url, encoding: .utf8).contains("暂无运行日志"))
}

@Test
func missingStoreAndInvalidShareFileHaveDifferentConditions() {
    #expect(SettingsViewModel.logStoreMissingFailure().condition == .logServiceUnavailable)
    #expect(LogExportDocument.invalidFileFailure().condition == .logExportFileInvalid)
}
```

- [ ] **Step 2: Run focused tests**

Run: `xcodebuild test -project Seal.xcodeproj -scheme Seal -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:SealTests/SealLogStoreTests -only-testing:SealTests/LogExportFailureTests`

Expected: FAIL until the three failure boundaries are explicit.

- [ ] **Step 3: Implement only the proved boundaries**

Keep `SealLogStore.materializeExport()` as the sole writer. Empty logs write a timestamped UTF-8 “暂无运行日志” file. Separately classify missing service, write failure, and invalid share URL; diagnostic records include build ID, whether a URL was generated, and redacted write error.

- [ ] **Step 4: Verify and commit**

Run: command from Step 2. Expected: PASS.

```powershell
git add Seal/Infrastructure/Diagnostics/SealLogStore.swift Seal/Features/Settings/SettingsViewModel.swift Seal/Features/Settings/LogViewerView.swift SealTests/Diagnostics/SealLogStoreTests.swift SealTests/Settings/LogExportFailureTests.swift
git commit -m "fix: make log export failures diagnosable"
```

### Task 6: Replace UI help with one direct-action presenter

**Files:**
- Create: `Seal/Features/Shared/FailureActionPresenter.swift`
- Test: `SealTests/Features/FailureActionPresenterTests.swift`
- Modify: `Seal/Features/Apps/AppsRootView.swift`, `Seal/Features/Apps/AppDetailView.swift`, `Seal/Features/Apps/AppSigningSheet.swift`, `Seal/Features/Settings/LogViewerView.swift`, `Seal/Features/Settings/SettingsRootView.swift`

- [ ] **Step 1: Write failing presenter tests**

```swift
@Test
func fullResignShowsOnlyTheProvenPrimaryAction() {
    let model = FailureActionPresenter.model(for: .profileOnlyAppIDMissing(operation: .renew))
    #expect(model.primaryTitle == "执行完整重签")
    #expect(model.route == nil)
    #expect(model.showsCopyDiagnostics)
}

@Test
func tunnelActionIsTheOnlyActionThatRoutesToLocalDevVPN() {
    let model = FailureActionPresenter.model(for: .tunnelUnavailable(operation: .install))
    #expect(model.primaryTitle == "打开 LocalDevVPN")
    #expect(model.route == .localDevVPN)
}
```

- [ ] **Step 2: Run test**

Run: `xcodebuild test -project Seal.xcodeproj -scheme Seal -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:SealTests/FailureActionPresenterTests`

Expected: FAIL because presenter does not exist.

- [ ] **Step 3: Implement and migrate all consumers**

Implement a value presenter model containing concise confirmed fact, primary title, optional route, and copy-diagnostics availability. Replace every “查看解决办法” alert/sheet with this direct path. Existing async recovery closures dispatch on `FailureAction`, never a code prefix.

- [ ] **Step 4: Build and commit**

Run: `xcodebuild build -project Seal.xcodeproj -scheme Seal -destination 'generic/platform=iOS Simulator'`

Expected: BUILD SUCCEEDED and no `ErrorHelpView` reference remains.

```powershell
git add Seal/Features/Shared/FailureActionPresenter.swift SealTests/Features/FailureActionPresenterTests.swift Seal/Features/Apps/AppsRootView.swift Seal/Features/Apps/AppDetailView.swift Seal/Features/Apps/AppSigningSheet.swift Seal/Features/Settings/LogViewerView.swift Seal/Features/Settings/SettingsRootView.swift
git commit -m "feat: present direct recovery actions"
```

### Task 7: Delete legacy help and enforce governance

**Files:**
- Delete: `Seal/Features/Settings/ErrorHelpView.swift`, `Seal/Core/Diagnostics/ErrorKnowledgeStore.swift`, `Seal/Resources/ErrorHelp/help-index.json`, `SealTests/Diagnostics/ErrorKnowledgeStoreTests.swift`
- Modify: `Scripts/error_catalog.py`, relevant `.github/workflows`, `DEBUG_LOG.md`

- [ ] **Step 1: Write the guard test**

```swift
@Test
func registeredFailuresHaveUniqueCodesAndActions() {
    let entries = FailureCatalog.all
    #expect(Set(entries.map(\.code)).count == entries.count)
    #expect(entries.allSatisfy { $0.action != .copyDiagnostics || $0.condition == .unexpected })
}
```

- [ ] **Step 2: Establish the failure baseline**

Run: `rg -n 'ErrorHelpView|ErrorKnowledgeStore|查看解决办法|hasPrefix\\("SEAL-|contains\\("SEAL-' Seal SealTests; python Scripts/error_catalog.py --check`

Expected: identifies all remaining legacy consumers before deletion.

- [ ] **Step 3: Delete only after compile migration**

Delete the four legacy files. Make `Scripts/error_catalog.py --check` parse `FailureCatalog`, validate unique code/action/route, and fail on feature-layer code-prefix routing. Update the existing workflow to run that one command.

- [ ] **Step 4: Verify deletion and commit**

Run: `rg -n 'ErrorHelpView|ErrorKnowledgeStore|查看解决办法' Seal SealTests; python Scripts/error_catalog.py --check`

Expected: no output from `rg`; catalog exits 0.

```powershell
git add -A -- Seal SealTests Scripts .github DEBUG_LOG.md
git commit -m "refactor: remove legacy error help system"
```

### Task 8: Whole-repository verification and handoff

**Files:**
- Modify only minimal source/test/doc files if verification proves a new reproducible defect.

- [ ] **Step 1: Run complete tests**

Run: `xcodebuild test -project Seal.xcodeproj -scheme Seal -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`

Expected: TEST SUCCEEDED.

- [ ] **Step 2: Run source and repository checks**

Run: `git diff --check; python Scripts/error_catalog.py --check; rg -n 'ErrorHelpView|ErrorKnowledgeStore|查看解决办法' Seal SealTests; git status --short`

Expected: whitespace clean, guard passes, old help absent, and no unrelated artifact staged.

- [ ] **Step 3: Update mandatory audit documentation and final commit if needed**

Append source evidence, regression command and result to `DEBUG_LOG.md`; if any signing/renewal semantic changed, update `docs/upstream-alignment.md`. Commit only verified residual fixes:

```powershell
git add <verified-files>
git commit -m "test: verify structured failure contract"
```

Do not push, dispatch CI, or claim an IPA exists unless explicitly requested and verified.

## Plan self-review

- Spec coverage: Tasks 1–2 implement semantic contract, audit identity, privacy and precedence; Tasks 3–4 cover Apple/profile/device truth; Task 5 handles actual log-export boundaries; Tasks 6–7 replace and remove the old help chain; Task 8 gates completion.
- Placeholder scan: every implementation task names exact files, failing test, command and expected result.
- Type consistency: `FailureCondition`, `FailureAction`, `FailureOperation`, `FailureOrigin`, `FailureRetryDisposition`, `FailureClassifier`, `FailureDiagnosticRecord`, `FailureCatalog` and `FailureActionPresenter` are introduced before use.

