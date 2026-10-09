# State Reconciliation and Maintenance Design

## Goal

Make the onboarding drawer a real native sheet, make successful signing and certificate revocation immediately visible everywhere, and give storage maintenance actions a truthful, reversible-data-preserving contract.

## Evidence and root causes

- `AgreementOnboardingView` draws a fixed rounded `VStack`; its handle has no sheet presentation or gesture. Because the enclosing `ZStack` is bottom-aligned, the 38% brand region is also bottom-aligned and therefore sits behind the 62% consent view.
- `AppSigningSheet` correctly resolves `workingApp` from `AppsViewModel.apps`, but certificate availability is an independently published derived snapshot. It must be recomputed whenever a successful signing changes an app's certificate serial, not only after a full reload/keychain read.
- Certificate inventory has two sources of truth (in-memory/cached inventory and remote inventory). Successful revocation already has a dismissal store, but every successful revocation path must atomically invalidate the in-flight refresh ticket, remove the serial from both in-memory and cached inventory, and persist the dismissal before any later refresh can publish stale data.
- Storage usage correctly classifies signed IPA files, and `AppFileStore.removeSignedIPA` exists, but the maintenance UI exposes no operation that reclaims that category. The current labels also imply broader cleanup than the implementation performs.

## Design

### Onboarding

`AgreementOnboardingView` becomes a background brand host plus a system `.sheet`. The sheet starts at a fixed short detent matching the current 62% visual height and may expand to `.large`; it uses the native drag indicator and is interactively non-dismissible. Agreement content uses a safe-area footer for the consent controls, so the controls remain reachable when the sheet expands or Dynamic Type grows. The host keeps the official Seal icon and compact copy visible above the short detent.

### Signing and certificate UI reconciliation

After any signed/installed record is persisted, `AppsViewModel` refreshes its account-secret snapshot and recomputes `localCertificateAvailabilityByAppID` from the current records and current secrets. This is a single post-operation reconciliation method so all signing/renewal exits use the same path. `AppSigningSheet` continues reading the live record by ID and receives the new derived certificate state in the same UI update.

Every successful certificate revocation uses one reconciliation method: persist the dismissal, invalidate stale refresh tickets, remove the serial from the in-memory inventory, save the filtered cache, refresh the affected account record/health, and refresh the published account list. Failed revocation remains visible and reports the failure; it is never hidden as if it had succeeded.

### Storage maintenance

The page offers three explicit operations:

1. **Clear temporary workspaces**: removes only `Seal/Temp` content.
2. **Clear unused files**: removes temporary workspaces plus orphaned app directories, holding the maintenance lease throughout.
3. **Clear regenerable signed packages**: removes only `Signed.ipa` and exports, preserves original IPA, records, icons, credentials, pairing, and installed apps, then marks the corresponding signed artifact missing so future install/renewal re-signs instead of referencing a deleted path.

Each operation measures storage immediately before and after, shows actual reclaimed bytes, and logs the exact scope. The destructive signed-package operation requires confirmation that it will require re-signing before the next installation.

## Acceptance

- The welcome icon/title are visible; the native sheet can expand/collapse but cannot dismiss the agreement gate.
- Immediately after signing, an open signing sheet no longer says the local certificate is missing; no manual refresh is required.
- After confirmed revocation, the certificate is absent from the certificate page and remains absent after a forced refresh while Apple propagation lags. Failed revocation remains displayed.
- Each storage action changes only its documented scope and reports non-negative reclaimed bytes. Clearing signed packages preserves original IPA and record metadata while clearing signed-artifact pointers.
