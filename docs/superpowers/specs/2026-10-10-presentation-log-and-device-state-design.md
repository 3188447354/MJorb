# Presentation, log export, and installed-state reconciliation

## Purpose

Remove four observable inconsistencies without weakening the existing signing,
renewal, or device-safety rules:

1. A stale action drawer flashes after signing, renewal, or batch renewal closes.
2. Log export can open an empty sheet saying that the log file does not exist.
3. After Seal replaces itself, its action drawer can retain the stale
   `需重新签名` certificate status until a manual refresh.
4. The agreement drawer can remain expanded after reading a policy.

This design also defines the boundary for synchronising an app that was
uninstalled outside Seal.

## Observed causes

- `AppsRootView` retains `installedActionApp` while `beginRenewalDirectly` starts
  an operation drawer. When the operation drawer dismisses, the retained value
  is again eligible for its independent `.sheet(item:)` binding.
- `LogViewerView` drives one sheet from independent `isExporting` and `exportURL`
  state. The fallback branch is reachable whenever SwiftUI evaluates the former
  before the latter has become visible to that view transaction.
- A `.sealSelfRecordUpdated` notification currently calls `load(force: true)`.
  `load` publishes the new records first and derives certificate availability in
  a detached Keychain read later. The drawer can therefore read a new record
  with the old availability map.
- The agreement sheet exposes both compact and large detents but owns no
  selected-detent state, so navigation into a policy and navigation back cannot
  restore the intended compact welcome state deterministically.

## Design

### 1. One visible operation drawer at a time

Keep the existing native sheets, but introduce a small, pure presentation
policy that receives the currently requested operation, installed-action,
detail, and batch-result routes. It must make these rules testable:

- Starting a single sign or renewal clears the installed action and detail
  routes before its progress drawer can be presented.
- Presenting a batch result clears all lower-priority routes first.
- Closing a completed result clears its own route before any other route is
  allowed to become eligible.
- No completion path uses a timed delay as a correctness mechanism.

`AppsRootView` will call a single routing helper at each transition rather than
mutating separate `@State` values in unrelated callbacks. Existing operation
and batch view models remain responsible for business state; the view owns
only presentation state.

### 2. Export only a materialised document

Replace `isExporting` plus optional `exportURL` with one optional
`LogExportDocument` value that is `Identifiable` and contains a verified URL.
The export task sets this value only after `SealLogStore.materializeExport()`
returns and the file is still present. `.sheet(item:)` receives that document;
there is no empty-sheet fallback.

Failures stay on the existing `ImportFailure` path with `SEAL-LOG-002` and do
not show a share sheet. A focused test will cover first-request export and the
policy that a missing URL cannot request presentation.

### 3. Atomic self-record and certificate-status reload

Add an explicit reload path for `.sealSelfRecordUpdated` that:

1. Reads the persisted app records and accounts.
2. Reads the corresponding Keychain secrets.
3. Publishes records, accounts, emails, and the derived certificate
   availability map together on the main actor.

The normal fast `load()` may remain progressively rendered for initial list
display. The self-record notification must use the atomic path, because it
changes the record field used by `ProfileOnlyRenewalPolicy` and is immediately
followed by user interaction. The result is that `需重新签名` disappears as
soon as the replacement Seal process has verified its real running identity;
it must not rely on a manual refresh.

### 4. Agreement drawer hierarchy

- The welcome drawer uses one fixed compact detent and no expandable grabber.
- Tapping either policy selects the large detent before navigation, so reading
  begins with adequate space rather than asking users to drag first.
- Returning to the welcome route selects the compact detent again.
- Remove the duplicate marketing line `为你的应用，保持可用。`; the standalone
  `Seal` title supplies sufficient branding. If the line were retained, its
  Chinese full stop would remain correct, but it is deliberately removed.

The consent gate, agreement links, and decline/reopen behavior remain intact.

### 5. Device uninstall synchronisation

An external uninstall can be confirmed only through an available paired iOS
device service (`Minimuxer.isAppInstalled`). Wi-Fi, LocalDevVPN, or another
working paired transport is therefore required for automatic truth-based
removal. Without that service, Seal must retain the local record: an iOS app
cannot receive a system-wide uninstall event for another app, and treating an
unreachable device as "uninstalled" would delete correct installed-state data.

Offer an explicit local-only `我已卸载` action if the current screen has an
appropriate operation menu. It marks the record missing locally while keeping
the original IPA, signed cache metadata, signing identity, and reinstall path.
The next successful device check remains authoritative.

## Error handling and safety

- Device checks retain the existing positive-control and "query all, then
  mutate" rules. A failed or untrusted transport removes no records.
- The log URL is checked after materialisation; no share sheet is shown for a
  missing artifact.
- Presentation changes do not alter signing, renewal admission, profile
  injection, installation, or cleanup semantics.

## Tests and acceptance

1. Presentation-policy tests prove stale installed/detail routes cannot appear
   when a single-operation or batch-result route is closing.
2. Log export tests prove a first export returns an existing readable file and
   that no nil document can present a sheet.
3. State-reload tests prove a self-record update publishes its matching
   certificate availability in the same observable update.
4. Agreement presentation-state tests prove policy navigation expands and back
   navigation restores compact state.
5. Existing installed-device reconciliation tests continue to prove that an
   unavailable device never removes local records.

Manual device acceptance: perform a Seal self-renewal installed through Aisi,
reopen Seal, then open Seal's action drawer immediately. It must show the
current certificate state without pull-to-refresh. Export logs from a fresh
launch; the native share panel must receive `Seal-log.txt` directly.
