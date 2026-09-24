# Seal

**Seal** is an on-device sideloading utility for iOS. It signs, installs, and renews IPA
packages using your own Apple ID — no AltServer, and no desktop companion involved in
signing or installing. After a one-time device pairing, the whole workflow runs on the
iPhone itself.

[![iOS](https://github.com/3188447354/MJorb/actions/workflows/ios.yml/badge.svg)](https://github.com/3188447354/MJorb/actions/workflows/ios.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)

---

## Table of contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Pairing](#pairing)
- [Getting Seal](#getting-seal)
- [Installing and updating](#installing-and-updating)
- [Built-in update check](#built-in-update-check)
- [Pairing assistant (Windows)](#pairing-assistant-windows)
- [Free Apple ID limits](#free-apple-id-limits)
- [Diagnostics](#diagnostics)
- [Building from source](#building-from-source)
- [Repository layout](#repository-layout)
- [Relationship to upstream](#relationship-to-upstream)
- [Documentation](#documentation)
- [Security](#security)
- [License](#license)
- [Disclaimer](#disclaimer)

---

## What it does

Seal owns the full lifetime of a sideloaded application:

| Stage | What happens |
| --- | --- |
| **Sign** | Requests a certificate and provisioning profiles from Apple, then re-signs the IPA on-device. App extensions are handled as first-class targets, including shared-profile mode. |
| **Install** | Uploads the signed package into the device's staging area and hands it to `installd` over a single cached pairing session. |
| **Renew** | Re-signs and re-installs before a 7-day free provisioning profile expires — per app, or in batch with resume-on-failure. |

Additional capabilities:

- Import and inspect IPAs — icon, version, embedded extensions, entitlements.
- Multiple Apple IDs, two-factor authentication, free and paid teams.
- Batch refresh with per-item results, failure retry, and self-renewal of Seal itself.
- Expiry reminders, connection diagnostics, log export, cache maintenance.
- On-device storage of account sessions, certificates, and pairing data. **Apple ID
  passwords are never stored.**

## Requirements

| | |
| --- | --- |
| **iOS** | 17.4 or later |
| **Apple ID** | Free or paid developer account |
| **Tunnel** | [LocalDevVPN](#pairing) installed and connected on the device |
| **Pairing** | A pairing file generated once by the Windows pairing assistant |
| **Bundle identifier** | `com.mjorb.seal` (URL schemes: `seal`, `sidestore`) |

Seal ships with **no built-in VPN extension**. The tunnel is an external dependency, so
the app can be re-signed without also re-signing a bundled network extension.

## Pairing

Seal needs a pairing file to talk to the device's own lockdown and installation services.
The pairing mode is chosen automatically from the device's iOS version — you do not pick it:

| iOS version | Pairing mode | Supported by Seal |
| --- | --- | --- |
| **17.4 and later** | Remote pairing (RPPairing / CoreDeviceProxy) | 1.3.8 and later |
| **17.0 – 17.3.1** | On-device pairing (Lockdown) | up to 1.3.7 |

**Seal 1.3.8 and later requires iOS 17.4**, so the Lockdown row applies only to Seal 1.3.7
and earlier. The pairing assistant still generates the correct file for both ranges, so those
older builds keep working — they are simply no longer updated.

Both modes require **LocalDevVPN** to be installed and connected. On the Lockdown path
Seal reaches the device through the VPN's loopback interface; without the tunnel the
device is simply unreachable.

The pairing file is written directly into Seal's `Documents` folder by the Windows
pairing assistant, and Seal imports it automatically on launch. Manual import
(Settings → Device Pairing → Import pairing file) remains available as a recovery path.

A pairing file is bound to the device on first successful validation. Later reachability
or tunnel state changes never overwrite that binding — only importing a new pairing file
does.

## Getting Seal

Seal is distributed as an **unsigned** IPA. You sign it with the sideloading tool of your
choice (Sideloadly, AltStore, SideStore, or any equivalent).

1. Open the repository's **Actions** tab and select the most recent successful `iOS` run.
2. Download the `Seal-<run number>` artifact. It contains:
   - `Seal_<version>.ipa` — the unsigned package
   - `Seal_<version>.ipa.sha256` — checksum
   - `Seal-Info.plist` — build metadata (`CFBundleVersion` equals the run number)
3. Sign and install the IPA with your own tooling.

Release builds are published to
[`sunuannian1/Seal-Releases`](https://github.com/sunuannian1/Seal-Releases).

## Installing and updating

- Keep the **same bundle identifier** (`com.mjorb.seal`) when overwriting an existing
  install. **Do not uninstall first** — uninstalling Seal removes its database and all
  imported packages, and the apps it signed are left behind with no records to manage them.
- Reinstalling Seal clears its keychain entries. If a certificate is revoked and a new one
  cannot be created, previously signed apps from that team stop launching.
- Signed packages are cached on-device, so re-installing an already-signed app does not
  require re-signing.

## Built-in update check

Seal compares its own `CFBundleShortVersionString` against the latest release of
`sunuannian1/Seal-Releases` and offers an in-app update when a strictly newer version is
published. The release tag must match the IPA's marketing version (`v1.3.6` ↔ `1.3.6`).

Consequences worth knowing:

- A rebuild that keeps the same version string is **not** delivered to existing installs.
  Delivering a new build requires bumping `MARKETING_VERSION`.
- The download link is only used when the release carries **exactly one** `.ipa` asset.
  With zero or multiple IPA assets, Seal falls back to opening the release page.
- Prerelease-tagged releases are not offered as updates.

## Pairing assistant (Windows)

`Tools/SealPairingAssistant/` builds the Windows helper that performs the one-time
pairing over USB. It is derived from upstream
[`jkcoxson/idevice_pair`](https://github.com/jkcoxson/idevice_pair) 0.1.14, which provides
the device protocols; Seal adds the product UI, iOS version routing, and the hand-off of
pairing credentials into Seal's `Documents` folder.

Prebuilt binaries are published as the `Seal-Pairing-Assistant-Windows-x64` artifact of
the **Seal Pairing Assistant** workflow.

Windows prerequisites follow upstream: install iTunes / the Apple Mobile Device components
from Apple so a usbmuxd channel is available. The helper detects Developer Mode, wireless
debugging, and the developer support files, and reports their real state.

## Free Apple ID limits

These are Apple's constraints, not Seal's, and no client-side change can lift them:

- Provisioning profiles issued to a free account expire after **7 days**.
- A free account can have **3 sideloaded apps per device**, counted across Apple IDs.
- A free account has **one certificate slot**.

Seal reports the specific failure code for each case so the next step is unambiguous
(see [Diagnostics](#diagnostics)).

## Diagnostics

**Log export.** Seal writes a ring-buffered log (most recent 1000 entries) and mirrors it
to `Documents`. To retrieve it: **Files → On My iPhone → Seal → `Seal-log.txt`**. Log
entries are redacted on both write and read; exported logs contain no keychain material
and no plaintext Apple ID.

**Error codes.** Every user-facing failure carries a stable code of the form
`SEAL-<MODULE>-<NNN>` together with a title, a reason, and a recovery action. Codes are
indexed in [`docs/qa/log-code-index.md`](docs/qa/log-code-index.md). When reporting a
problem, the code is more useful than the message text.

**Release safety guard.** Static invariants for the signing, installation, and renewal
paths are enforced by:

```bash
python3 Scripts/verify-release-safety.py
```

It runs on every CI build, and covers both source-shape assertions and mutation checks
(that deliberately broken variants are actually caught).

## Building from source

The Xcode project is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(pinned to 2.45.4 in CI); the Swift toolchain and macOS SDK are only available on CI. Pushing
to a non-`main` branch touching `Seal/**`, `SealTests/**`, `SealUITests/**`, `Vendor/**`,
`project.yml`, `Config/**`, or `Scripts/**` triggers a full build and test run.

On Windows, the Rust bridge can be type-checked locally:

```bash
cd Vendor/Minimuxer/RustBridge && cargo check
```

The Rust bridge targets iOS 16.0 as a minimum and is verified by
`Scripts/verify-rustbridge-minos.sh`.

### CI workflows

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `iOS` | push (any branch except `main`), pull request, dispatch | Full gate: release build, packaging, Swift tests, UI regression |
| `iOS Fast IPA` | push to `main`, dispatch | Fast debug build for a quick installable package |
| `iOS Release Fast` | dispatch | Build and, when explicitly requested, publish a release |
| `Seal Pairing Assistant` | push to `main` / `feature/**`, dispatch | Build the Windows pairing helper |
| `Rebuild RustBridge` | push to `feature/seal-optimization`, dispatch | Rebuild the Rust bridge artifacts |

Releases are never published by a plain push: the `publish-release` job only runs on an
explicit dispatch with `publish_release` enabled.

## Repository layout

```
Seal/                      Application source (Swift)
  App/, Application/       App entry points and lifecycle
  Core/                    Signing, renewal, installation, maintenance
  Features/                SwiftUI screens
  Infrastructure/          Portal, pairing, update, logging
  DesignSystem/            Shared visual components
  Resources/               Info.plist, entitlements, Anisette runtime, notices
SealTests/                 Unit tests (swift-testing, 90 test files)
SealUITests/               UI regression tests
Vendor/                    Vendored dependencies
  Minimuxer/               Rust bridge + device communication (minOS 16.0)
  SideSign/, CodeSignKit/  Re-signing engine (from upstream SideStore)
  AnisetteKit/, GSACryptoKit/, DeviceSupport/, libdeflate/
Tools/SealPairingAssistant/ Windows pairing helper and its upstream patch script
Scripts/                   Release guard, build and packaging helpers
docs/                      Engineering notes, QA reports, upstream alignment
upstream/                  Read-only upstream reference — not compiled
project.yml                XcodeGen project definition
AGENTS.md                  Engineering conventions and constraints
DEBUG_LOG.md               Postmortem ledger (symptom → root cause → fix → verification)
RELEASE_NOTES.md           Source of release notes; newest version first
```

The repository is named `MJorb`; the application is Seal.

## Relationship to upstream

Seal is a derivative work. The upstream projects are **AltStore** and **SideStore** —
SideStore being AltStore's fork that removes the AltServer requirement, which makes it the
closer reference for Seal's architecture.

Because Seal's git history was rebuilt, it shares no common ancestor with upstream, so
`git merge` and `git rebase` are not applicable. Alignment is therefore done by **semantic
comparison**: upstream files are read, approaches are compared, and conclusions are
recorded in [`docs/upstream-alignment.md`](docs/upstream-alignment.md). Both outcomes are
recorded there — where Seal follows upstream, and where it deliberately does not.

The re-signing engine is upstream SideStore's `SideSign` + `CodeSignKit`, vendored rather
than patched. The `upstream/` directory is a read-only reference and is never compiled.

## Documentation

| Document | Contents |
| --- | --- |
| [`AGENTS.md`](AGENTS.md) | Engineering conventions, hard constraints, pre-change checklist |
| [`DEBUG_LOG.md`](DEBUG_LOG.md) | Postmortem ledger, newest first |
| [`RELEASE_NOTES.md`](RELEASE_NOTES.md) | Release notes, newest version first |
| [`docs/upstream-alignment.md`](docs/upstream-alignment.md) | Upstream comparison ledger |
| [`docs/qa/log-code-index.md`](docs/qa/log-code-index.md) | Index of `SEAL-*` diagnostic codes |
| [`docs/qa/device-regression-checklist.md`](docs/qa/device-regression-checklist.md) | On-device regression checklist |
| [`docs/qa/pairing-os-support-matrix.md`](docs/qa/pairing-os-support-matrix.md) | Pairing mode by iOS version |

## Security

- Never commit certificates, provisioning profiles, Apple ID credentials, or pairing files.
  The repository and CI both check for common sensitive files.
- Exported logs are redacted and never contain keychain material or plaintext Apple IDs.
- The built-in updater validates that download URLs point at GitHub-owned hosts, and
  cross-checks the release tag against the downloaded IPA's own version before offering an
  in-app install.
- Third-party components and their licenses are listed in
  [`Seal/Resources/ThirdPartyNotices.txt`](Seal/Resources/ThirdPartyNotices.txt).

## License

Seal is licensed under the **GNU Affero General Public License v3.0**. See [`LICENSE`](LICENSE)
and [`Seal/Resources/ThirdPartyNotices.txt`](Seal/Resources/ThirdPartyNotices.txt).

## Disclaimer

Seal is not affiliated with, endorsed by, or sponsored by Apple Inc. Sideloading may
conflict with Apple's terms of service, and re-signing an application can invalidate its
data container or keychain access group. Use at your own risk.
