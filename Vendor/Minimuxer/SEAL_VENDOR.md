# Vendored Minimuxer

Seal vendors the official SideStore Minimuxer Swift package from:

- Source: https://github.com/SideStore/minimuxer
- Revision: `e3614068c77fb09945eff363fbc3f9e8abf4c834`
- License: GNU Affero General Public License v3.0

The package includes its corresponding Swift and Rust source. The XCFramework is
limited to the iOS device and arm64 iOS Simulator slices used by Seal; the unused
macOS slice is omitted to keep the repository and CI artifact smaller.

## Seal local hardening

Seal carries a small compatibility/safety delta on top of the pinned Minimuxer revision:

- Rust FFI objects use type-specific destructors instead of a generic `void *` free.
- Swift service wrappers retain the originating Rust device for the complete borrowed-client lifetime.
- FFI string/buffer inputs are validated for null pointers, UTF-8, and `UInt32` length overflow.
- Remote-pairing state is replaceable; changing the pairing file invalidates the cached RSD connection.
- **Readiness probes poll with a dedicated short budget.** `Minimuxer.ready()` and
  `Minimuxer.fetchUDIDDetailed()` pass `MuxerConstants.probeDeviceFetchTimeoutMs` (1 s) to
  `Device.getFirstDevice(timeoutMs:)` instead of the 15 s default, and `ready()` evaluates the cheap
  predicates before querying the device. Both call sites sit inside the 36-round retry loop in
  `MinimuxerInstallChannel.diagnose()`. Two different quantities must be kept apart: the **wait** is
  `min(outer bounded wait, inner budget)` — `isReady()` wraps `Minimuxer.ready()` in a 5-second
  `offThread`, so the nominal upper bound was only **≈3.4 minutes** (36 × (5 s + 0.5 s sleep)) and the
  15-second default never extended it; the **cost** is that each round abandons a blocking FFI which
  keeps running for another 15 seconds, occupying a Swift cooperative-pool thread and delaying the
  resumption of later `Task.sleep`s and timers. That is what dragged the field measurement to
  **12+ minutes** on the Lockdown path (iOS 17.0–17.3.1, build 184) — the key win of the fix is
  shrinking the abandoned call from 15 s to 1 s. `readyDeviceIdentifier()` begins with
  `guard await isReady() else { return nil }`, so `fetchUDIDDetailed()` is never reached while
  `ready()` is false — each round pays one probe only. After the fix the same path fails in
  **~20–60 seconds** (≈20 s with the tunnel down,
  ≈56 s with the tunnel up but the device unreachable). One-shot callers
  (dump / install / DDI / JIT) keep the 15-second default. Guarded by `R61`.
- Explicit Rust `unwrap`/`expect`/`panic` shortcuts are removed from the bridge boundary.
- The checked-in RustBridge binary must be rebuilt with an iOS 16.0 deployment target and pass
  `Scripts/verify-rustbridge-minos.sh` and `Scripts/verify-rustbridge-symbols.sh` before replacement.
