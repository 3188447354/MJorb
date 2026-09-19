# GSACryptoKit

A high-performance, pure Swift Secure Remote Password (SRP-6a) authentication client and cryptographic utilities library for **GrandSlam (GSA)** services across **iOS, macOS, tvOS, and visionOS** via Swift Package Manager.

---

## Background

GrandSlam Authentication (GSA) infrastructure relies on the Secure Remote Password protocol (SRP-6a, RFC 2945 / RFC 5054) to perform zero-knowledge password authentication without transmitting credentials in plaintext over the wire.

---

## Features

- **Pure Swift SRP-6a Protocol Client**: Full client implementation of the RFC 5054 2048-bit Modular Exponential (MODP) group SRP-6a handshake matching GSA server specifications.
- **Zero Plaintext Credentials**: Computes ephemeral public keys ($A$), session proof ($M_1$), and verifies server proof ($M_2$) with zero knowledge exposure.
- **Key Derivation (PBKDF2)**: Implements PBKDF2-HMAC-SHA256 key derivation matching client encryption standards.
- **Symmetric Ciphers**: Provides AES-CBC (128/192/256-bit with PKCS#7 padding) and authenticated AES-GCM decryption routines.
- **Cross-Platform**: Portable SPM package to be usable across windows, linux, macOS, ios, tvOS, etc.

---

## Platforms Supported

| Platform                          | Runtime Mode | Dependency Requirements     |
| :-------------------------------- | :----------- | :-------------------------- |
| **iOS (Real Device & Simulator)** | Native Swift | `swift-crypto` (Pure Swift) |
| **macOS (ARM64 & x86_64)**        | Native Swift | `swift-crypto` (Pure Swift) |
| **tvOS (Device & Simulator)**     | Native Swift | `swift-crypto` (Pure Swift) |
| **visionOS (Device & Simulator)** | Native Swift | `swift-crypto` (Pure Swift) |
| **watchOS (Device & Simulator)**  | Native Swift | `swift-crypto` (Pure Swift) |
| **Linux (ARM64 & x86_64)**        | Native Swift | `swift-crypto` (Pure Swift) |
| **Windows (x86_64)**              | Native Swift | `swift-crypto` (Pure Swift) |

---

## Installation

Add `GSACryptoKit` to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/mahee96/GSACryptoKit.git", branch: "main")
]


```

Or add it to your target:

```swift
.target(
    name: "MyTarget",
    dependencies: ["GSACryptoKit"]
)
```

---

## Public API Reference

### `SRPClient`

Manages client-side SRP-6a authentication state machine for GSA authentication.

#### `init?()`

- **When to use**: Initializes an SRP client instance, allocates 2048-bit MODP parameters ($N, g$), and generates the client private/public ephemeral pair ($a, A$).

#### `getClientEphemeralA() -> Data?`

- **When to use**: Returns the 256-byte client public ephemeral key ($A$) to send in the initial authentication challenge request.

#### `computeSessionKey(salt:serverPublicKeyB:password:username:) -> (m1: Data, m2: Data)?`

- **When to use**: Processes server salt and server public key ($B$) from the challenge response to derive the shared session key ($K$), returning client evidence ($M_1$) and expected server evidence ($M_2$).
- **Parameters**:
  - `salt`: Server challenge salt `Data`.
  - `serverPublicKeyB`: Server ephemeral key $B$ `Data`.
  - `password`: User password string.
  - `username`: GSA Username string.
- **Returns**: Tuple `(m1, m2)` containing client proof $M_1$ and expected server verification proof $M_2$.

#### `verifyServerProof(serverM2:) -> Bool`

- **When to use**: Validates the server evidence response against expected $M_2$ to confirm mutual authentication.

#### `sessionKey`

- **When to use**: Property holding the 32-byte shared session key ($K$) after successful key exchange.

---

### `CryptoUtilities`

Cryptographic helper utilities for symmetric decryption and hashing.

#### `hmacSHA256(key:strings:) -> Data?`

- **When to use**: Computes HMAC-SHA256 over concatenated UTF-8 string arrays.

#### `sha256(_:) -> Data?`

- **When to use**: Computes SHA-256 digest over arbitrary binary `Data`.

#### `pbkdf2SHA256(password:salt:rounds:outputLength:) -> Data?`

- **When to use**: Derives cryptographic keys using PBKDF2-HMAC-SHA256.

#### `aesCBCDecrypt(key:iv:ciphertext:) -> Data?`

- **When to use**: Decrypts AES-CBC encrypted payloads with PKCS#7 unpadding.

#### `aesGCMDecrypt(key:nonce:aad:ciphertext:tag:) -> Data?`

- **When to use**: Decrypts authenticated AES-GCM payloads with authentication tag verification.

---

## Disclaimer

This project is provided for **educational and research purposes only**.

- `GSACryptoKit` is an independent project and is not affiliated with, sponsored by, or endorsed by Apple Inc.
- Use of this software is entirely at your own risk. The author and contributors assume no responsibility or liability for any damages, locked accounts, or legal repercussions arising from the use or distribution of this code.
- By using this library, you agree to comply with all applicable terms, laws, and regulations.

---

## License & Terms

`GSACryptoKit` is licensed under the **GNU Affero General Public License v3.0 (AGPLv3)**.

### Key Terms:

- **Strong Copyleft**: Any application, framework, or tool that compiles against, links against (statically or dynamically), or includes `GSACryptoKit` is considered a combined/derivative work and **must be fully open-sourced under the AGPLv3** upon distribution.
- **Network / Cloud Trigger (AGPL Section 13)**: If you run `GSACryptoKit` as part of any network service, cloud auth API, or remote server, you **must make the complete, corresponding source code of the entire service and all linked software available** to all users interacting with it over the network.
- **Closed-Source / Proprietary Use Prohibited**: Closed-source, commercial, or proprietary distribution without full source disclosure is **strictly prohibited** under the AGPLv3.
- **App Store Distribution Prohibited**: Inclusion in, linking against, or distribution through any App Store builds is **strictly prohibited**.

Copyright © 2026 GSACryptoKit. All rights reserved.

Full license information can be found at [LICENSE](./LICENSE)
