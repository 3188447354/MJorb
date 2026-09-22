# Seal 1.0 Self-Renewal Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让电脑签名安装的 Seal 在不导入电脑 P12、不提前撤销当前证书的前提下，基于真实 Mach-O 签名身份创建本机身份，并通过一次安装提交、下次启动确认的事务完成自续签接管。

**Architecture:** 保留现有 Apple Portal、RorkSign、Minimuxer、Keychain 和 AppStore 实现。新增独立的“已安装身份读取器”和“自替换事务协调器”，由真实 CMS 签名证书而不是描述文件证书列表驱动判断；`SigningCoordinator` 只负责产出签名包并把 Seal 安装委托给事务协调器，`SelfAppRegistrar` 只负责启动对账和记录同步。

**Tech Stack:** Swift 6、Swift Testing、SwiftUI、CryptoKit、ZIPFoundation、RorkSign、Core Data、Keychain、Minimuxer、XcodeGen、iOS 17+

---

## 文件结构

新增文件：

- `Seal/Core/Renewal/SelfSigningIdentity.swift`：定义 target、已安装身份、候选身份、本机身份和用户态状态。
- `Seal/Infrastructure/Renewal/AppBundleSigningIdentityReader.swift`：读取 `.app`/`.appex` 的 Info.plist、描述文件和真实 Mach-O CMS 签名证书。
- `Seal/Infrastructure/Renewal/SignedIPAIdentityReader.swift`：从候选 IPA 解出临时 App，复用 AppBundle 读取器验证主程序与扩展。
- `Seal/Core/Renewal/SelfReplacementTransaction.swift`：事务数据、阶段、提交语义和兼容旧 handoff 的解码模型。
- `Seal/Core/Renewal/SelfReplacementPolicy.swift`：纯函数状态迁移和启动对账。
- `Seal/Core/Renewal/SelfReplacementCoordinator.swift`：Prepare、Submit Once、Reconcile、Settle 编排。
- `SealTests/Renewal/AppBundleSigningIdentityReaderTests.swift`：真实签名结果映射与未知状态测试。
- `SealTests/Renewal/SignedIPAIdentityReaderTests.swift`：候选主程序、扩展和签名一致性测试。
- `SealTests/Renewal/SelfReplacementTransactionTests.swift`：原子持久化、一次提交和旧记录迁移测试。
- `SealTests/Renewal/SelfReplacementPolicyTests.swift`：全部状态迁移测试。
- `SealTests/Renewal/SelfReplacementCoordinatorTests.swift`：安装超时、中断、重启确认和结算测试。

修改文件：

- `Seal/Infrastructure/Renewal/ProvisioningProfileReader.swift`：为描述文件证书增加 SHA-256 指纹，保留现有序列号接口。
- `Seal/Core/Renewal/SelfAppMetadata.swift`：附带真实 InstalledIdentity，不再把授权证书列表解释成实际签名者。
- `Seal/Core/Renewal/SelfSigningHandoffStore.swift`：迁移旧记录后删除，由新事务 Store 接管原文件路径。
- `Seal/Core/Renewal/SelfAppRegistrar.swift`：删除启动自动补装，只执行对账、结算和 AppRecord 同步。
- `Seal/Core/Signing/SigningCoordinator.swift`：删除 Seal 双次安装及当前进程确认，把 Seal 分支交给 SelfReplacementCoordinator。
- `Seal/Core/Signing/CertificateCleanupPolicy.swift`：以真实 Seal 签名序列号作为不可撤销保护对象。
- `Seal/Features/Settings/SettingsViewModel.swift`：证书分析和执行前复核统一使用真实身份。
- `Seal/Features/Settings/SigningCertificateSettingsView.swift`：展示外部启动、本机准备、等待确认、自管理和电脑恢复状态。
- `Seal/Application/AppContainer.swift`：创建并注入身份读取器、事务 Store 和协调器。
- `SealTests/Renewal/SelfSigningHandoffTests.swift`：迁移后删除或改写为事务 Store 测试。
- `SealTests/Renewal/SelfAppPendingHandoffTests.swift`：改为验证“只对账、不自动重装”。
- `SealTests/Renewal/SelfAppRegistrarTests.swift`：使用真实身份快照测试注册和结算。
- `SealTests/Signing/CertificateCleanupPolicyTests.swift`：增加真实签名证书不可撤销测试。
- `SealTests/Signing/SigningCoordinatorSignedArtifactTests.swift`：断言 Seal 安装只委托一次。

## Task 1：让描述文件保留证书指纹证据

**Files:**

- Modify: `Seal/Infrastructure/Renewal/ProvisioningProfileReader.swift:4-62`
- Test: `SealTests/Renewal/ProvisioningProfileReaderTests.swift`

- [ ] **Step 1: 写失败测试，证明证书序列号与 SHA-256 指纹同时保留**

在现有描述文件 fixture 测试旁增加：

```swift
@Test
func developerCertificateIdentityUsesDERFingerprint() {
    let certificate = ProvisioningProfileReader.developerCertificateIdentity(
        der: Data([0x01, 0x02, 0x03]),
        serialNumber: "0001"
    )
    #expect(certificate.serialNumber == "0001")
    #expect(
        certificate.sha256Fingerprint
            == "039058C6F2C0CB492C533B0A4D14EF77CC0F78ABCCCED5287D84A1A2011CFB81"
    )
}
```

- [ ] **Step 2: 运行测试并确认失败**

Run:

```bash
xcodegen generate
bash Scripts/ci-test.sh -only-testing:SealTests/ProvisioningProfileReaderTests
```

Expected: FAIL，`Details` 没有 `developerCertificates`。

- [ ] **Step 3: 添加稳定的证书身份模型**

在 `ProvisioningProfileReader` 内加入：

```swift
import CryptoKit

struct DeveloperCertificateIdentity: Sendable, Equatable {
    let serialNumber: String
    let sha256Fingerprint: String
}

struct Details: Sendable, Equatable {
    // 保留现有字段
    let developerCertificates: [DeveloperCertificateIdentity]

    var certificateSerialNumbers: [String] {
        developerCertificates.map(\.serialNumber)
    }
}

private static func certificateIdentity(_ data: Data) -> DeveloperCertificateIdentity? {
    guard let serialNumber = certificateSerialNumber(data) else { return nil }
    return developerCertificateIdentity(der: data, serialNumber: serialNumber)
}

static func developerCertificateIdentity(
    der data: Data,
    serialNumber: String
) -> DeveloperCertificateIdentity {
    let fingerprint = SHA256.hash(data: data)
        .map { String(format: "%02X", $0) }
        .joined()
    return DeveloperCertificateIdentity(
        serialNumber: serialNumber,
        sha256Fingerprint: fingerprint
    )
}
```

构造 `Details` 时使用：

```swift
developerCertificates: certificateData.compactMap(Self.certificateIdentity)
```

删除存储型 `certificateSerialNumbers` 参数，所有调用继续通过计算属性读取，避免两份数组漂移。

- [ ] **Step 4: 运行描述文件和签名前置校验回归**

Run:

```bash
bash Scripts/ci-test.sh \
  -only-testing:SealTests/ProvisioningProfileReaderTests \
  -only-testing:SealTests/ProvisioningProfileBindingTests \
  -only-testing:SealTests/PreInstallValidationTests
```

Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Seal/Infrastructure/Renewal/ProvisioningProfileReader.swift SealTests/Renewal/ProvisioningProfileReaderTests.swift
git commit -m "feat: retain provisioning certificate fingerprints"
```

## Task 2：建立统一的自续签身份模型

**Files:**

- Create: `Seal/Core/Renewal/SelfSigningIdentity.swift`
- Test: `SealTests/Renewal/SelfSigningIdentityTests.swift`

- [ ] **Step 1: 写失败测试，固定完整性与匹配规则**

```swift
import Testing
@testable import Seal

struct SelfSigningIdentityTests {
    @Test
    func installedIdentityRequiresMainAndEveryExtensionToBeComplete() {
        let complete = InstalledIdentity.fixture(targets: [.mainFixture, .extensionFixture])
        let incomplete = InstalledIdentity.fixture(targets: [.mainFixture, .unknownExtensionFixture])
        #expect(complete.isComplete)
        #expect(incomplete.isComplete == false)
    }

    @Test
    func candidateMatchesOnlyExactTargetSetAndSigner() {
        let installed = InstalledIdentity.fixture(targets: [.mainFixture, .extensionFixture])
        let candidate = CandidateIdentity.fixture(targets: [.mainFixture, .extensionFixture])
        #expect(candidate.matches(installed))
        #expect(candidate.replacingSigner(serialNumber: "OTHER").matches(installed) == false)
    }
}
```

- [ ] **Step 2: 运行并确认类型不存在**

Run:

```bash
bash Scripts/ci-test.sh -only-testing:SealTests/SelfSigningIdentityTests
```

Expected: FAIL，找不到 `InstalledIdentity`。

- [ ] **Step 3: 实现值类型和显式未知状态**

```swift
import Foundation

enum IdentityReadStatus: String, Codable, Sendable {
    case complete
    case unreadable
    case inconsistentArchitectures
    case signerNotAuthorizedByProfile
}

struct SignedTargetIdentity: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case mainApp, appExtension }
    let kind: Kind
    let bundleIdentifier: String
    let teamIdentifier: String
    let applicationIdentifier: String
    let profileUUID: String
    let profileExpirationDate: Date
    let signerSerialNumber: String
    let signerCertificateSHA256: String
    let status: IdentityReadStatus

    var isComplete: Bool { status == .complete }
}

struct InstalledIdentity: Codable, Equatable, Sendable {
    let bundleURL: URL
    let version: String
    let buildNumber: String
    let targets: [SignedTargetIdentity]
    let readErrors: [String]

    var mainTarget: SignedTargetIdentity? {
        targets.first { $0.kind == .mainApp }
    }

    var isComplete: Bool {
        readErrors.isEmpty && mainTarget != nil && targets.allSatisfy(\.isComplete)
    }

    static func unknown(bundleIdentifier: String) -> Self {
        Self(
            bundleURL: URL(fileURLWithPath: "/unknown/\(bundleIdentifier).app"),
            version: "",
            buildNumber: "",
            targets: [],
            readErrors: ["由旧版 handoff 迁移，缺少安装前真实身份快照"]
        )
    }
}

struct CandidateIdentity: Codable, Equatable, Sendable {
    let transactionID: UUID
    let ipaSHA256: String
    let version: String
    let buildNumber: String
    let targets: [SignedTargetIdentity]

    var mainBundleIdentifier: String {
        targets.first(where: { $0.kind == .mainApp })?.bundleIdentifier ?? ""
    }

    func matches(_ installed: InstalledIdentity) -> Bool {
        installed.isComplete
            && version == installed.version
            && buildNumber == installed.buildNumber
            && targets.sorted(by: Self.order) == installed.targets.sorted(by: Self.order)
    }

    private static func order(_ lhs: SignedTargetIdentity, _ rhs: SignedTargetIdentity) -> Bool {
        lhs.bundleIdentifier < rhs.bundleIdentifier
    }

    static func legacy(
        transactionID: UUID,
        bundleIdentifier: String,
        teamIdentifier: String,
        profileUUID: String,
        certificateSerialNumber: String
    ) -> Self {
        Self(
            transactionID: transactionID,
            ipaSHA256: "",
            version: "",
            buildNumber: "",
            targets: [.init(
                kind: .mainApp,
                bundleIdentifier: bundleIdentifier,
                teamIdentifier: teamIdentifier,
                applicationIdentifier: "",
                profileUUID: profileUUID,
                profileExpirationDate: .distantPast,
                signerSerialNumber: certificateSerialNumber,
                signerCertificateSHA256: "",
                status: .unreadable
            )]
        )
    }
}

struct LocalSigningIdentity: Codable, Equatable, Sendable {
    let accountID: UUID
    let teamIdentifier: String
    let certificateSerialNumber: String
    let certificateSHA256: String
    let expirationDate: Date
    let hasMatchingPrivateKey: Bool

    var isUsable: Bool {
        hasMatchingPrivateKey && expirationDate > Date()
    }
}

enum SelfManagementState: String, Codable, Sendable {
    case externalBootstrap
    case preparingLocalIdentity
    case localIdentityReady
    case awaitingReplacementConfirmation
    case selfManaged
    case recoveryRequired
}

enum SelfReplacementProcess {
    static let currentID = UUID()
}
```

测试 fixture 放在测试文件的 `private extension` 中，不加入生产 target。

- [ ] **Step 4: 运行身份测试**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/SelfSigningIdentityTests`

Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Seal/Core/Renewal/SelfSigningIdentity.swift SealTests/Renewal/SelfSigningIdentityTests.swift
git commit -m "feat: define self signing identity model"
```

## Task 3：读取主程序和扩展的真实 CMS 签名证书

**Files:**

- Create: `Seal/Infrastructure/Renewal/AppBundleSigningIdentityReader.swift`
- Modify: `Seal/Core/Renewal/SelfAppMetadata.swift:4-63`
- Create: `SealTests/Renewal/AppBundleSigningIdentityReaderTests.swift`

- [ ] **Step 1: 写失败测试，拒绝把描述文件第一张证书当成签名者**

生产读取器把 RorkSign 适配层注入为闭包，单测无需伪造真实证书：

```swift
@Test
func choosesCMSActualSignerInsteadOfFirstAuthorizedCertificate() throws {
    let fixture = try IdentityBundleFixture.make(
        authorized: [
            .init(serialNumber: "AAAA", sha256Fingerprint: String(repeating: "A", count: 64)),
            .init(serialNumber: "BBBB", sha256Fingerprint: String(repeating: "B", count: 64))
        ]
    )
    let reader = AppBundleSigningIdentityReader(
        inspectExecutable: { _ in
            .init(serialNumber: "BBBB", cmsValid: true, codeDirectoryValid: true)
        }
    )

    let identity = try reader.read(bundleURL: fixture.bundleURL)
    #expect(identity.mainTarget?.signerSerialNumber == "BBBB")
    #expect(identity.mainTarget?.signerCertificateSHA256 == String(repeating: "B", count: 64))
}
```

再增加三个测试：主程序无法读取为 `unreadable`；两个架构签名者不同为 `inconsistentArchitectures`；任一 `.appex` 失败时整个 InstalledIdentity 不完整。

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/AppBundleSigningIdentityReaderTests`

Expected: FAIL，读取器不存在。

- [ ] **Step 3: 用 RorkSign 的现有 CMS 检查实现适配器**

```swift
import Foundation
import RorkSign

struct ExecutableSignerEvidence: Equatable, Sendable {
    let serialNumber: String
    let cmsValid: Bool
    let codeDirectoryValid: Bool
}

struct AppBundleSigningIdentityReader: Sendable {
    typealias Inspector = @Sendable (URL) throws -> ExecutableSignerEvidence
    private let inspectExecutable: Inspector

    init(inspectExecutable: @escaping Inspector = Self.inspectWithRorkSign) {
        self.inspectExecutable = inspectExecutable
    }

    private static func inspectWithRorkSign(_ executableURL: URL) throws -> ExecutableSignerEvidence {
        let reports = try RorkSigner.checkMachOCodeSignatures(at: executableURL)
        guard reports.isEmpty == false,
              let serial = reports.first?.signingCertificate?.serialNumberHex else {
            throw IdentityReadFailure.signerMissing
        }
        let normalized = SigningCertificateSelectionPolicy.normalizedSerialNumber(serial)
        guard reports.allSatisfy({
            $0.cmsSignatureValid
                && $0.codeDirectoryHashesValid
                && SigningCertificateSelectionPolicy.normalizedSerialNumber(
                    $0.signingCertificate?.serialNumberHex ?? ""
                ) == normalized
        }) else {
            throw IdentityReadFailure.inconsistentArchitectures
        }
        return ExecutableSignerEvidence(
            serialNumber: normalized,
            cmsValid: true,
            codeDirectoryValid: true
        )
    }
}
```

`readTarget(bundleURL:kind:)` 必须按以下固定顺序实现：

```swift
let infoURL = bundleURL.appending(path: "Info.plist")
let info = try PropertyListSerialization.propertyList(
    from: Data(contentsOf: infoURL), format: nil
) as? [String: Any]
let bundleID = try requiredString("CFBundleIdentifier", in: info)
let executableName = try requiredString("CFBundleExecutable", in: info)
let profile = try ProvisioningProfileReader().details(
    from: Data(contentsOf: bundleURL.appending(path: "embedded.mobileprovision"))
)
let evidence = try inspectExecutable(bundleURL.appending(path: executableName))
let signer = profile.developerCertificates.first {
    SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber)
        == SigningCertificateSelectionPolicy.normalizedSerialNumber(evidence.serialNumber)
}
```

找不到 `signer` 时返回 `signerNotAuthorizedByProfile`，不得退回 `.first`。扩展只枚举 `PlugIns/*.appex`，按 Bundle ID 排序，任何读取失败都写入 `readErrors`。

- [ ] **Step 4: 让 SelfAppMetadata 附带真实身份**

加入：

```swift
var installedIdentity: InstalledIdentity? = nil

@MainActor
static func current(
    bundle: Bundle = .main,
    identityReader: AppBundleSigningIdentityReader = .init()
) -> SelfAppMetadata? {
    // 保留现有展示字段。identity 读取失败时仍创建 SelfAppMetadata，
    // 但 installedIdentity 为 nil，所有撤销和接管操作因此关闭。
    let identity = try? identityReader.read(bundleURL: bundle.bundleURL)
    // 只有 identity 完整时才用 mainTarget 填充真实 signer；授权证书列表只作诊断。
}
```

读取失败不能使 Seal 消失：`AppBundleSigningIdentityReader.read` 应返回带 `readErrors` 的 InstalledIdentity；只有 Bundle 基础信息缺失才让 `current` 返回 nil。

- [ ] **Step 5: 运行单元测试和 RorkSign 自身 CMS 回归**

Run:

```bash
bash Scripts/ci-test.sh \
  -only-testing:SealTests/AppBundleSigningIdentityReaderTests \
  -only-testing:SealTests/SelfAppRegistrarTests
swift test --package-path Vendor/rork-sign --filter IdentitySigningTests
```

Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add Seal/Core/Renewal/SelfAppMetadata.swift Seal/Infrastructure/Renewal/AppBundleSigningIdentityReader.swift SealTests/Renewal/AppBundleSigningIdentityReaderTests.swift
git commit -m "feat: read actual Seal code signing identity"
```

## Task 4：验证候选 IPA 的主程序与所有扩展身份

**Files:**

- Create: `Seal/Infrastructure/Renewal/SignedIPAIdentityReader.swift`
- Create: `SealTests/Renewal/SignedIPAIdentityReaderTests.swift`
- Modify: `SealTests/Import/Fixtures/IPAArchiveFixture.swift`

- [ ] **Step 1: 写失败测试**

```swift
@Test
func candidateRequiresExactMainAndExtensionSigners() throws {
    let fixture = try IPAArchiveFixture.signedSeal(
        mainSigner: "BBBB",
        extensionSigner: "BBBB"
    )
    let candidate = try SignedIPAIdentityReader(
        bundleReader: fixture.reader
    ).read(ipaData: fixture.data, transactionID: UUID())

    #expect(candidate.targets.count == 2)
    #expect(Set(candidate.targets.map(\.signerSerialNumber)) == ["BBBB"])
}

@Test
func mismatchedExtensionMakesCandidateInvalid() throws {
    let fixture = try IPAArchiveFixture.signedSeal(
        mainSigner: "BBBB",
        extensionSigner: "CCCC"
    )
    #expect(throws: IdentityReadFailure.self) {
        try SignedIPAIdentityReader(bundleReader: fixture.reader)
            .read(ipaData: fixture.data, transactionID: UUID())
    }
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/SignedIPAIdentityReaderTests`

Expected: FAIL，读取器不存在。

- [ ] **Step 3: 实现临时解包、读取、摘要和必清理语义**

```swift
import CryptoKit
import Foundation
import ZIPFoundation

struct SignedIPAIdentityReader: Sendable {
    let bundleReader: AppBundleSigningIdentityReader

    func read(ipaData: Data, transactionID: UUID) throws -> CandidateIdentity {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SealCandidate-\(transactionID.uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ipaURL = root.appending(path: "Candidate.ipa")
        let unpacked = root.appending(path: "Unpacked", directoryHint: .isDirectory)
        try ipaData.write(to: ipaURL, options: .atomic)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: ipaURL, to: unpacked)
        let payload = unpacked.appending(path: "Payload", directoryHint: .isDirectory)
        let apps = try FileManager.default.contentsOfDirectory(
            at: payload,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "app" }
        guard apps.count == 1 else { throw IdentityReadFailure.invalidIPA }
        let installedShape = try bundleReader.read(bundleURL: apps[0])
        guard installedShape.isComplete else { throw IdentityReadFailure.incompleteIdentity }
        let serials = Set(installedShape.targets.map(\.signerSerialNumber))
        guard serials.count == 1 else { throw IdentityReadFailure.targetSignerMismatch }
        return CandidateIdentity(
            transactionID: transactionID,
            ipaSHA256: SHA256.hash(data: ipaData).map { String(format: "%02X", $0) }.joined(),
            version: installedShape.version,
            buildNumber: installedShape.buildNumber,
            targets: installedShape.targets
        )
    }
}
```

这里固定使用项目已经在 `SigningWorkspace` 中采用的 `FileManager.unzipItem(at:to:)`，不另建第二套 ZIP 解压实现。

- [ ] **Step 4: 运行测试**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/SignedIPAIdentityReaderTests`

Expected: PASS；测试结束后临时目录不存在。

- [ ] **Step 5: 提交**

```bash
git add Seal/Infrastructure/Renewal/SignedIPAIdentityReader.swift SealTests/Renewal/SignedIPAIdentityReaderTests.swift SealTests/Import/Fixtures/IPAArchiveFixture.swift
git commit -m "feat: validate candidate Seal signing identity"
```

## Task 5：用持久事务替换 handoff 记录

**Files:**

- Create: `Seal/Core/Renewal/SelfReplacementTransaction.swift`
- Create: `Seal/Core/Renewal/SelfReplacementTransactionStore.swift`
- Test: `SealTests/Renewal/SelfReplacementTransactionTests.swift`
- Modify: `Seal/Core/Renewal/SelfSigningHandoffStore.swift`

- [ ] **Step 1: 写一次提交和旧记录迁移失败测试**

```swift
@Test
func submissionCanBeClaimedOnlyOnceEvenAfterRestart() async throws {
    let fileURL = TransactionFixture.temporaryFileURL()
    let store = SelfReplacementTransactionStore(fileURL: fileURL)
    let transaction = try await store.create(.fixture)
    let first = try await store.claimSubmission(transactionID: transaction.id)
    #expect(first.claimedAt <= Date())

    let restarted = SelfReplacementTransactionStore(fileURL: fileURL)
    await #expect(throws: SelfReplacementStoreError.alreadySubmitted) {
        try await restarted.claimSubmission(transactionID: transaction.id)
    }
}

@Test
func legacyHandoffMigratesToAwaitingConfirmation() async throws {
    let fixture = try TransactionFixture.withLegacyHandoff()
    let transaction = try #require(await fixture.store.loadPending())
    #expect(transaction.phase == .awaitingReplacementConfirmation)
    #expect(transaction.submission != nil)
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/SelfReplacementTransactionTests`

Expected: FAIL，新事务类型不存在。

- [ ] **Step 3: 实现事务和值语义**

```swift
import Foundation

struct SelfReplacementTransaction: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case prepared
        case submitting
        case awaitingReplacementConfirmation
        case installedOldIdentity
        case settling
        case confirmed
        case recoveryRequired
    }

    struct Submission: Codable, Equatable, Sendable {
        let id: UUID
        let claimedAt: Date
        var returnedAt: Date?
        var transportResult: String?
    }

    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    let accountID: UUID
    let preparedProcessID: UUID
    let installedBefore: InstalledIdentity
    let candidate: CandidateIdentity
    let signedIPARelativePath: String
    var phase: Phase
    var submission: Submission?
    var settledAt: Date?
    var failureCode: String?

    static func make(
        id: UUID,
        accountID: UUID,
        preparedProcessID: UUID,
        installedBefore: InstalledIdentity,
        candidate: CandidateIdentity,
        signedIPARelativePath: String,
        now: Date = Date()
    ) -> Self {
        Self(
            schemaVersion: 1,
            id: id,
            createdAt: now,
            updatedAt: now,
            accountID: accountID,
            preparedProcessID: preparedProcessID,
            installedBefore: installedBefore,
            candidate: candidate,
            signedIPARelativePath: signedIPARelativePath,
            phase: .prepared,
            submission: nil,
            settledAt: nil,
            failureCode: nil
        )
    }
}
```

Store 的公开接口固定为：

```swift
actor SelfReplacementTransactionStore {
    func create(_ transaction: SelfReplacementTransaction) throws -> SelfReplacementTransaction
    func loadPending() throws -> SelfReplacementTransaction?
    func requirePending(id: UUID) throws -> SelfReplacementTransaction
    func claimSubmission(transactionID: UUID) throws -> SelfReplacementTransaction.Submission
    func recordTransportReturn(transactionID: UUID, result: String) throws
    func updatePhase(transactionID: UUID, phase: SelfReplacementTransaction.Phase, failureCode: String?) throws
    func markSettled(transactionID: UUID) throws
}
```

`claimSubmission` 必须先写入 `.submitting` 与本地生成的 `submissionID`，原子写盘成功后才返回。已有 `submission` 时一律抛出 `alreadySubmitted`，不根据安装 API 返回值清零。

- [ ] **Step 4: 兼容迁移旧 SelfSigningHandoff.json**

新 Store 首次加载时：先尝试新 schema；失败后尝试解码旧 `SelfSigningHandoff`。旧记录迁移为 `.awaitingReplacementConfirmation`，并创建固定的 migration submission，防止升级后自动重装。迁移成功后以新格式原子覆盖同一路径。

迁移代码必须具有以下结果：

```swift
SelfReplacementTransaction(
    schemaVersion: 1,
    id: legacy.id,
    createdAt: legacy.automaticRecoveryAttemptedAt ?? .distantPast,
    updatedAt: Date(),
    accountID: legacy.accountID,
    preparedProcessID: legacy.preparedInProcess,
    installedBefore: .unknown(bundleIdentifier: legacy.bundleIdentifier),
    candidate: .legacy(
        transactionID: legacy.id,
        bundleIdentifier: legacy.bundleIdentifier,
        teamIdentifier: legacy.teamIdentifier,
        profileUUID: legacy.profileUUID,
        certificateSerialNumber: legacy.certificateSerialNumber
    ),
    signedIPARelativePath: "",
    phase: .awaitingReplacementConfirmation,
    submission: .init(id: legacy.id, claimedAt: .distantPast),
    settledAt: nil,
    failureCode: nil
)
```

- [ ] **Step 5: 运行 Store 测试**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/SelfReplacementTransactionTests`

Expected: PASS，包括写盘失败时不返回提交资格。

- [ ] **Step 6: 提交**

```bash
git add Seal/Core/Renewal/SelfReplacementTransaction.swift Seal/Core/Renewal/SelfReplacementTransactionStore.swift Seal/Core/Renewal/SelfSigningHandoffStore.swift SealTests/Renewal/SelfReplacementTransactionTests.swift
git commit -m "feat: persist self replacement transactions"
```

## Task 6：实现纯函数启动对账策略

**Files:**

- Create: `Seal/Core/Renewal/SelfReplacementPolicy.swift`
- Create: `SealTests/Renewal/SelfReplacementPolicyTests.swift`

- [ ] **Step 1: 写完整状态表测试**

```swift
@Test(arguments: [
    ReconcileCase(candidateMatches: true, oldMatches: false, readable: true, expected: .settle),
    ReconcileCase(candidateMatches: false, oldMatches: true, readable: true, expected: .closeAsNotInstalled),
    ReconcileCase(candidateMatches: false, oldMatches: false, readable: true, expected: .requireRecovery),
    ReconcileCase(candidateMatches: false, oldMatches: false, readable: false, expected: .requireRecovery)
])
func reconciliationNeverRequestsAutomaticInstall(testCase: ReconcileCase) {
    #expect(SelfReplacementPolicy.reconcile(testCase.input) == testCase.expected)
}
```

另测同一进程只能返回 `.awaitNextLaunch`，主 App 匹配但扩展不匹配返回 `.requireRecovery`。

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/SelfReplacementPolicyTests`

Expected: FAIL，策略不存在。

- [ ] **Step 3: 实现没有“自动重装”出口的策略**

```swift
enum SelfReplacementReconcileAction: Equatable, Sendable {
    case none
    case awaitNextLaunch
    case settle
    case closeAsNotInstalled
    case requireRecovery(reason: String)
}

enum SelfReplacementPolicy {
    static func reconcile(
        transaction: SelfReplacementTransaction,
        running: InstalledIdentity,
        currentProcessID: UUID,
        preparedProcessID: UUID
    ) -> SelfReplacementReconcileAction {
        guard transaction.phase != .confirmed else { return .none }
        guard currentProcessID != preparedProcessID else { return .awaitNextLaunch }
        guard running.isComplete else {
            return .requireRecovery(reason: "无法完整读取当前 Seal 主程序和扩展身份")
        }
        if transaction.candidate.matches(running) { return .settle }
        if running == transaction.installedBefore { return .closeAsNotInstalled }
        return .requireRecovery(reason: "当前 Seal 与安装前身份、候选身份都不一致")
    }
}
```

策略枚举中不得出现 `.retryInstall`、`.recoverAutomatically` 或同义动作。

- [ ] **Step 4: 运行测试**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/SelfReplacementPolicyTests`

Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Seal/Core/Renewal/SelfReplacementPolicy.swift SealTests/Renewal/SelfReplacementPolicyTests.swift
git commit -m "feat: reconcile self replacement from installed identity"
```

## Task 7：新增自替换协调器并保证只提交一次

**Files:**

- Create: `Seal/Core/Renewal/SelfReplacementCoordinator.swift`
- Create: `SealTests/Renewal/SelfReplacementCoordinatorTests.swift`

- [ ] **Step 1: 写安装返回、超时和抛错均不允许二次提交的测试**

```swift
@Test(arguments: [InstallOutcome.success, .timeout, .connectionLost])
func submitCallsInstallExactlyOnce(outcome: InstallOutcome) async throws {
    let channel = CountingInstallChannel(outcome: outcome)
    let fixture = try await CoordinatorFixture.make(channel: channel)

    _ = try? await fixture.coordinator.submitPrepared(
        transactionID: fixture.transaction.id,
        progress: { _ in }
    )

    #expect(await channel.installCallCount == 1)
    #expect(try await fixture.store.loadPending()?.submission != nil)
}

@Test
func secondSubmitForSameTransactionIsRejectedBeforeChannelCall() async throws {
    let fixture = try await CoordinatorFixture.make(channel: CountingInstallChannel())
    _ = try? await fixture.coordinator.submitPrepared(transactionID: fixture.transaction.id, progress: { _ in })
    await #expect(throws: SelfReplacementStoreError.alreadySubmitted) {
        try await fixture.coordinator.submitPrepared(transactionID: fixture.transaction.id, progress: { _ in })
    }
    #expect(await fixture.channel.installCallCount == 1)
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/SelfReplacementCoordinatorTests`

Expected: FAIL，协调器不存在。

- [ ] **Step 3: 实现 Prepare 和 Submit Once**

```swift
actor SelfReplacementCoordinator {
    private let store: SelfReplacementTransactionStore
    private let identityReader: AppBundleSigningIdentityReader
    private let ipaIdentityReader: SignedIPAIdentityReader
    private let installChannel: any InstallChannel
    private let fileStore: AppFileStore
    private let keychain: KeychainVault
    private let processID: UUID

    func prepare(
        app: AppRecord,
        accountID: UUID,
        signedIPARelativePath: String
    ) async throws -> SelfReplacementTransaction {
        let running = try identityReader.read(bundleURL: Bundle.main.bundleURL)
        guard running.isComplete else { throw SelfReplacementFailure.runningIdentityUnknown }
        let ipaData = try await fileStore.read(relativePath: signedIPARelativePath)
        let id = UUID()
        let candidate = try ipaIdentityReader.read(ipaData: ipaData, transactionID: id)
        guard candidate.targets.map(\.bundleIdentifier).sorted()
                == running.targets.map(\.bundleIdentifier).sorted() else {
            throw SelfReplacementFailure.bundleShapeChanged
        }
        guard let secret = try await keychain.load(accountID: accountID),
              let signerSerial = candidate.targets.first?.signerSerialNumber,
              candidate.targets.allSatisfy({
                  SigningCertificateSelectionPolicy.normalizedSerialNumber($0.signerSerialNumber)
                      == SigningCertificateSelectionPolicy.normalizedSerialNumber(signerSerial)
              }),
              let localCertificate = SigningCertificateMaterialPolicy.availableCertificate(
                  secret: secret,
                  serialNumber: signerSerial
              ),
              SigningCertificateMaterialPolicy.reuseStatus(localCertificate) == .reusable else {
            throw SelfReplacementFailure.localSigningIdentityUnavailable
        }
        let transaction = SelfReplacementTransaction.make(
            id: id,
            accountID: accountID,
            preparedProcessID: processID,
            installedBefore: running,
            candidate: candidate,
            signedIPARelativePath: signedIPARelativePath
        )
        return try await store.create(transaction)
    }

    func submitPrepared(
        transactionID: UUID,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let transaction = try await store.requirePending(id: transactionID)
        let data = try await fileStore.read(relativePath: transaction.signedIPARelativePath)
        guard SHA256.hexDigest(data) == transaction.candidate.ipaSHA256 else {
            throw SelfReplacementFailure.candidateChanged
        }
        _ = try await store.claimSubmission(transactionID: transactionID)
        do {
            try await installChannel.install(
                ipaData: data,
                bundleID: transaction.candidate.mainBundleIdentifier,
                isSelfReplacement: true,
                onProgress: progress
            )
            try await store.recordTransportReturn(transactionID: transactionID, result: "returned")
        } catch {
            try? await store.recordTransportReturn(transactionID: transactionID, result: "threw")
            throw error
        }
    }
}
```

`recordTransportReturn` 无论结果是 `returned` 还是 `threw` 都把 phase 写为 `.awaitingReplacementConfirmation`，因为底层安装在超时或断连后仍可能继续执行。`submitPrepared` 不调用 `verifyInstalled`，不读取当前进程 Bundle，不循环，不 reset 后重传。`SHA256.hexDigest` 作为 `SelfReplacementCoordinator` 内的私有 helper 实现，输出与 CandidateIdentity 相同的 64 位大写十六进制。

- [ ] **Step 4: 实现 Reconcile 与 Settle 接口**

```swift
func reconcileAtLaunch() async throws -> SelfReplacementReconcileAction {
    guard let transaction = try await store.loadPending() else { return .none }
    let running = try identityReader.read(bundleURL: Bundle.main.bundleURL)
    return SelfReplacementPolicy.reconcile(
        transaction: transaction,
        running: running,
        currentProcessID: processID,
        preparedProcessID: transaction.preparedProcessID
    )
}
```

`.settle` 只更新事务和返回结算结果；AppRecord 与 profile 清理由下一任务的 Registrar 执行，以保持协调器职责单一。

- [ ] **Step 5: 运行测试**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/SelfReplacementCoordinatorTests`

Expected: PASS，所有 outcome 的安装调用数均为 1。

- [ ] **Step 6: 提交**

```bash
git add Seal/Core/Renewal/SelfReplacementCoordinator.swift SealTests/Renewal/SelfReplacementCoordinatorTests.swift
git commit -m "feat: submit self replacement exactly once"
```

## Task 8：把 SigningCoordinator 的 Seal 分支切到新事务

**Files:**

- Modify: `Seal/Core/Signing/SigningCoordinator.swift:26-54,768-876,1158-1330`
- Modify: `Seal/Application/AppContainer.swift:75-138`
- Modify: `SealTests/Signing/SigningCoordinatorSignedArtifactTests.swift`

- [ ] **Step 1: 写失败测试，固定委托边界**

```swift
@Test
func SealInstallDelegatesOnePreparedTransaction() async throws {
    let replacement = RecordingSelfReplacementCoordinator()
    let coordinator = try SigningCoordinatorFixture.make(selfReplacement: replacement)

    _ = try? await coordinator.signAndInstall(
        appID: coordinator.sealID,
        accountID: coordinator.accountID,
        forceResign: true
    )

    #expect(await replacement.prepareCount == 1)
    #expect(await replacement.submitCount == 1)
}
```

- [ ] **Step 2: 运行并确认旧双安装路径未通过测试**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/SigningCoordinatorSignedArtifactTests`

Expected: FAIL，旧构造器没有 `selfReplacement`，或计数不符合。

- [ ] **Step 3: 注入协议并替换 Seal 安装分支**

```swift
protocol SelfReplacing: Actor {
    func prepare(app: AppRecord, accountID: UUID, signedIPARelativePath: String) async throws -> SelfReplacementTransaction
    func submitPrepared(transactionID: UUID, progress: @escaping @Sendable (Double) async -> Void) async throws
}
```

在签名包完成并通过现有 `SignedArtifactValidator` 后：

```swift
if app.isSeal {
    let transaction = try await selfReplacement.prepare(
        app: updated,
        accountID: accountID,
        signedIPARelativePath: signedPath
    )
    try await updateState(appID: app.id, stage: .pushing)
    await progress(.pushing)
    try await selfReplacement.submitPrepared(
        transactionID: transaction.id,
        progress: onInstallProgress
    )
    updated.signedArtifactStatus = .awaitingVerification
    try await appStore.save(updated)
    return updated
}
```

删除：

- `for attempt in 1...2`。
- Seal 分支中的 `verifyInstalled`。
- 当前进程读取 `SelfAppMetadata.current()` 后确认成功。
- `recoverPendingSelfReplacement()`。
- Seal 安装返回后推进 `expiryDate`、`.installed` 和清理旧 profile 的代码。

非 Seal App 的安装路径保持不变。

- [ ] **Step 4: 更新 AppContainer 注入**

```swift
let identityReader = AppBundleSigningIdentityReader()
let transactionStore = SelfReplacementTransactionStore(
    fileURL: sealDirectory.appending(path: "SelfSigningHandoff.json")
)
let selfReplacement = SelfReplacementCoordinator(
    store: transactionStore,
    identityReader: identityReader,
    ipaIdentityReader: SignedIPAIdentityReader(bundleReader: identityReader),
    installChannel: installChannel,
    fileStore: fileStore,
    keychain: keychain,
    processID: SelfReplacementProcess.currentID
)
```

把 `selfReplacement` 注入 `SigningCoordinator` 和 `SelfAppRegistrar`，删除 `pendingSelfReplacementRecovery` 闭包。

- [ ] **Step 5: 运行签名和容器回归**

Run:

```bash
bash Scripts/ci-test.sh \
  -only-testing:SealTests/SigningCoordinatorSignedArtifactTests \
  -only-testing:SealTests/ApplicationOperationCoordinatorTests
```

Expected: PASS。

- [ ] **Step 6: 用搜索证明旧入口消失**

Run:

```bash
rg -n "for attempt in 1\.\.\.2|recoverPendingSelfReplacement|pendingSelfReplacementRecovery|claimAutomaticRecovery" Seal
```

Expected: 无结果。

- [ ] **Step 7: 提交**

```bash
git add Seal/Core/Signing/SigningCoordinator.swift Seal/Application/AppContainer.swift SealTests/Signing/SigningCoordinatorSignedArtifactTests.swift
git commit -m "refactor: route Seal installs through replacement transaction"
```

## Task 9：启动只对账、成功后精准结算

**Files:**

- Modify: `Seal/Core/Renewal/SelfAppRegistrar.swift:4-194,325-397`
- Modify: `Seal/Infrastructure/Installation/DeviceProfileCleaner.swift`
- Modify: `SealTests/Renewal/SelfAppPendingHandoffTests.swift`
- Modify: `SealTests/Renewal/SelfAppRegistrarTests.swift`

- [ ] **Step 1: 写“启动永不安装”和结算顺序测试**

```swift
@Test
func startupReconciliationNeverCallsInstallChannel() async throws {
    let fixture = try await RegistrarFixture.pendingCandidateMatchesRunning()
    try await fixture.registrar.ensureRegistered()
    #expect(await fixture.installChannel.installCallCount == 0)
}

@Test
func confirmedReplacementAdvancesRecordBeforeCleaningOldProfile() async throws {
    let fixture = try await RegistrarFixture.pendingCandidateMatchesRunning()
    try await fixture.registrar.ensureRegistered()
    let app = try #require(await fixture.appStore.fetchAll().first(where: \.isSeal))
    #expect(app.certificateSerialNumber == fixture.candidateSigner)
    #expect(app.provisioningProfileUUID == fixture.candidateProfileUUID)
    #expect(await fixture.profileCleaner.keptUUID == fixture.candidateProfileUUID)
    #expect(try await fixture.transactionStore.loadPending() == nil)
}
```

- [ ] **Step 2: 运行并确认旧启动补装路径导致失败**

Run:

```bash
bash Scripts/ci-test.sh \
  -only-testing:SealTests/SelfAppPendingHandoffTests \
  -only-testing:SealTests/SelfAppRegistrarTests
```

Expected: FAIL，旧 Registrar 会触发 recovery 闭包或仍按授权列表确认。

- [ ] **Step 3: 把 Registrar 改成纯启动对账消费者**

```swift
private func reconcileSelfReplacement() async throws -> Bool {
    switch try await selfReplacement.reconcileAtLaunch() {
    case .none, .awaitNextLaunch:
        return false
    case .closeAsNotInstalled:
        try await selfReplacement.closeAsNotInstalled()
        return false
    case .requireRecovery(let reason):
        try await selfReplacement.requireRecovery(reason: reason)
        return false
    case .settle:
        let settled = try await selfReplacement.settle()
        try await atomicallyApplyInstalledIdentity(settled.installedIdentity)
        let cleanup = await profileCleaner.removeStaleProfiles(
            for: settled.mainBundleIdentifier,
            keeping: settled.mainProfileUUID
        )
        try await selfReplacement.finishCleanup(cleanup)
        return true
    }
}
```

`atomicallyApplyInstalledIdentity` 必须从 `InstalledIdentity.mainTarget` 写入真实 signer serial、profile UUID、Team 和到期时间；不得读取 `certificateSerialNumbers.first`。

- [ ] **Step 4: 收紧 profile 清理接口**

为 `DeviceProfileCleaner` 新增显式请求：

```swift
struct ProfileCleanupRequest: Sendable {
    let transactionID: UUID
    let bundleIdentifier: String
    let keepingProfileUUID: String
    let installedIdentityReadAt: Date
}
```

清理前重新读取 InstalledIdentity；若当前 profile UUID 不等于 `keepingProfileUUID`，返回 `.skippedIdentityChanged`，不删除任何 profile。清理失败记录到事务审计，但不回滚已确认的安装身份。

- [ ] **Step 5: 运行 Registrar 和 profile 测试**

Run:

```bash
bash Scripts/ci-test.sh \
  -only-testing:SealTests/SelfAppPendingHandoffTests \
  -only-testing:SealTests/SelfAppRegistrarTests \
  -only-testing:SealTests/ProvisioningProfileReaderTests
```

Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add Seal/Core/Renewal/SelfAppRegistrar.swift Seal/Infrastructure/Installation/DeviceProfileCleaner.swift SealTests/Renewal/SelfAppPendingHandoffTests.swift SealTests/Renewal/SelfAppRegistrarTests.swift
git commit -m "feat: settle self replacement on next launch"
```

## Task 10：让证书接管与保护逻辑只相信真实签名者

**Files:**

- Create: `Seal/Core/Signing/CertificateTakeoverPolicy.swift`
- Modify: `Seal/Core/Signing/CertificateCleanupPolicy.swift`
- Modify: `Seal/Core/Signing/SigningCoordinator.swift:560-720`
- Modify: `Seal/Features/Settings/SettingsViewModel.swift:422-760`
- Modify: `SealTests/Signing/CertificateCleanupPolicyTests.swift`
- Create: `SealTests/Signing/CertificateTakeoverPolicyTests.swift`
- Modify: `SealTests/Settings/CertificateRevocationImpactTests.swift`

- [ ] **Step 1: 写失败测试，A 永远不能成为撤销候选**

```swift
@Test
func actualSealSignerIsProtectedWhenProfileAuthorizesTwoCertificates() {
    let plan = CertificateCleanupPolicy.makePlan(
        certificates: [.fixture(serial: "A"), .fixture(serial: "C")],
        apps: [],
        localUsableSerials: [],
        deviceReferencedSerials: ["A", "C"],
        sealActualSignerSerialNumber: "A",
        identityConfidence: .complete
    )
    #expect(plan.revocable.contains(where: { $0.serialNumber == "A" }) == false)
}

@Test
func unknownSealSignerDisablesAllAutomaticRevocation() {
    let plan = CertificateCleanupPolicy.makePlan(
        certificates: [.fixture(serial: "A"), .fixture(serial: "C")],
        apps: [],
        localUsableSerials: [],
        deviceReferencedSerials: nil,
        sealActualSignerSerialNumber: nil,
        identityConfidence: .unreadable
    )
    #expect(plan.revocable.isEmpty)
}
```

- [ ] **Step 2: 运行并确认旧 `.first` 逻辑不满足测试**

Run:

```bash
bash Scripts/ci-test.sh \
  -only-testing:SealTests/CertificateCleanupPolicyTests \
  -only-testing:SealTests/CertificateRevocationImpactTests
```

Expected: FAIL，旧接口没有真实 signer 参数。

- [ ] **Step 3: 替换所有 Seal 证书保护输入**

统一通过：

```swift
let runningIdentity = await MainActor.run { SelfAppMetadata.current()?.installedIdentity }
guard runningIdentity?.isComplete == true,
      let sealSigner = runningIdentity?.mainTarget?.signerSerialNumber else {
    return CertificateCleanupPlan.blocked(reason: "无法确认当前 Seal 的真实签名证书")
}
```

删除以下形式：

```swift
SelfAppMetadata.current()?.certificateSerialNumbers.first
Set(SelfAppMetadata.current()?.certificateSerialNumbers ?? [])
```

执行撤销前必须重新读取一次真实身份；如果 signer 或读取完整性变化，整批撤销停止。只把非 A 证书作为用户确认候选，不自动撤销。

- [ ] **Step 4: 固定空槽位和满槽位的接管决策**

```swift
enum CertificateTakeoverDecision: Equatable, Sendable {
    case reuseLocal(serialNumber: String)
    case createLocal
    case requestRevocation(candidateSerialNumbers: [String])
    case blocked(reason: String)
}

enum CertificateTakeoverPolicy {
    private static func normalize(_ value: String) -> String {
        SigningCertificateSelectionPolicy.normalizedSerialNumber(value)
    }

    static func decide(
        remoteSerialNumbers: [String],
        localUsableSerialNumbers: Set<String>,
        actualSealSignerSerialNumber: String?,
        identityComplete: Bool,
        maximumCertificates: Int = 2
    ) -> CertificateTakeoverDecision {
        guard identityComplete, let actualSealSignerSerialNumber else {
            return .blocked(reason: "无法确认当前 Seal 的真实签名证书")
        }
        if let local = remoteSerialNumbers.first(where: {
            localUsableSerialNumbers.contains(normalize($0))
        }) {
            return .reuseLocal(serialNumber: local)
        }
        if remoteSerialNumbers.count < maximumCertificates { return .createLocal }
        let protected = normalize(actualSealSignerSerialNumber)
        let candidates = remoteSerialNumbers.filter { normalize($0) != protected }
        guard candidates.isEmpty == false else {
            return .blocked(reason: "没有可以安全释放的证书槽位")
        }
        return .requestRevocation(candidateSerialNumbers: candidates)
    }
}
```

对应测试必须覆盖：`[A] → createLocal`、`[A,C] → requestRevocation([C])`、未知 A → blocked、本机已有 B → reuseLocal(B)。`SettingsViewModel` 在用户确认 C 后重新拉远端清单、重新读取 A，再撤销 C；撤销成功后重新拉清单确认出现空位，才调用现有创建证书能力创建 B。B 创建失败时不得清除 A 的任何本地或 App 记录。

- [ ] **Step 5: 运行证书测试**

Run:

```bash
bash Scripts/ci-test.sh \
  -only-testing:SealTests/CertificateCleanupPolicyTests \
  -only-testing:SealTests/CertificateTakeoverPolicyTests \
  -only-testing:SealTests/CertificateRevocationImpactTests \
  -only-testing:SealTests/OrphanCertificateAutoCleanupTests
```

Expected: PASS。

- [ ] **Step 6: 搜索危险推断**

Run:

```bash
rg -n "SelfAppMetadata\.current\(\)\?\.certificateSerialNumbers\.first|runningSealSerials" Seal
```

Expected: 无结果。

- [ ] **Step 7: 提交**

```bash
git add Seal/Core/Signing/CertificateTakeoverPolicy.swift Seal/Core/Signing/CertificateCleanupPolicy.swift Seal/Core/Signing/SigningCoordinator.swift Seal/Features/Settings/SettingsViewModel.swift SealTests/Signing/CertificateTakeoverPolicyTests.swift SealTests/Signing/CertificateCleanupPolicyTests.swift SealTests/Settings/CertificateRevocationImpactTests.swift
git commit -m "fix: protect actual Seal signing certificate"
```

## Task 11：把事务状态暴露给证书页

**Files:**

- Modify: `Seal/Features/Settings/SettingsViewModel.swift`
- Modify: `Seal/Features/Settings/SigningCertificateSettingsView.swift`
- Modify: `Seal/Application/AppContainer.swift`
- Create: `SealTests/Settings/SelfManagementPresentationTests.swift`

- [ ] **Step 1: 写状态到文案的纯函数测试**

```swift
@Test(arguments: [
    PresentationCase(.externalBootstrap, "电脑签名，等待本机接管"),
    PresentationCase(.preparingLocalIdentity, "正在准备本机签名身份"),
    PresentationCase(.localIdentityReady, "本机身份已就绪"),
    PresentationCase(.awaitingReplacementConfirmation, "已提交安装，等待重新打开 Seal 确认"),
    PresentationCase(.selfManaged, "Seal 已由本机管理"),
    PresentationCase(.recoveryRequired, "需要电脑覆盖恢复")
])
func stateHasPlainLanguageSummary(testCase: PresentationCase) {
    #expect(SelfManagementPresentation(testCase.state).title == testCase.title)
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/SelfManagementPresentationTests`

Expected: FAIL，展示模型不存在。

- [ ] **Step 3: 在 ViewModel 汇总状态，不让 View 自己猜**

```swift
struct SelfManagementPresentation: Equatable, Sendable {
    let state: SelfManagementState
    let title: String
    let detail: String
    let allowsInstall: Bool
    let showsComputerRecovery: Bool

    init(_ state: SelfManagementState) {
        self.state = state
        let values: (String, String, Bool, Bool)
        switch state {
        case .externalBootstrap:
            values =
                ("电脑签名，等待本机接管", "先准备 Seal 本机可控的签名证书。", true, false)
        case .preparingLocalIdentity:
            values =
                ("正在准备本机签名身份", "请保持 Seal 在前台。", false, false)
        case .localIdentityReady:
            values =
                ("本机身份已就绪", "可以提交一次覆盖安装。", true, false)
        case .awaitingReplacementConfirmation:
            values =
                ("已提交安装，等待重新打开 Seal 确认", "不会自动再次安装。", false, false)
        case .selfManaged:
            values =
                ("Seal 已由本机管理", "后续续签复用本机证书。", true, false)
        case .recoveryRequired:
            values =
                ("需要电脑覆盖恢复", "不要卸载 Seal。", false, true)
        }
        title = values.0
        detail = values.1
        allowsInstall = values.2
        showsComputerRecovery = values.3
    }
}

@Published private(set) var selfManagement: SelfManagementPresentation =
    .init(.externalBootstrap)
```

`SettingsViewModel.refreshCertificateInventory` 同时读取 InstalledIdentity 和未结算事务：

- 无事务且真实 signer 不属于本机私钥：`.externalBootstrap`。
- 事务 `.prepared`：`.localIdentityReady`。
- 已有 submission：`.awaitingReplacementConfirmation`，`allowsInstall = false`。
- 当前身份与本机身份匹配：`.selfManaged`。
- 事务或身份不可确认：`.recoveryRequired`。

- [ ] **Step 4: 更新证书页顶部状态卡**

状态卡固定展示：当前真实签名者、本机可用身份、事务状态和下一步。等待确认时按钮只允许“检查安装结果”；恢复状态显示“不卸载 Seal，使用电脑同 Bundle ID、扩展标识和 Team 覆盖安装”。

证书标签使用以下固定含义：

```swift
enum CertificateRoleLabel {
    case currentSealSigner       // 当前 Seal 实际使用
    case locallyUsable           // 本机持有匹配私钥
    case external                // Apple 端存在但本机没有私钥
    case associatedOnThisDevice  // 只统计本机已安装 App
    case associationUnknown      // 无法确认
}
```

- [ ] **Step 5: 运行展示和证书测试**

Run:

```bash
bash Scripts/ci-test.sh \
  -only-testing:SealTests/SelfManagementPresentationTests \
  -only-testing:SealTests/CertificateRevocationImpactTests
```

Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add Seal/Features/Settings/SettingsViewModel.swift Seal/Features/Settings/SigningCertificateSettingsView.swift Seal/Application/AppContainer.swift SealTests/Settings/SelfManagementPresentationTests.swift
git commit -m "feat: show Seal self management state"
```

## Task 12：删除旧 handoff 路径并完成自动化回归

**Files:**

- Delete: `Seal/Core/Renewal/SelfSigningHandoffStore.swift`
- Delete: `SealTests/Renewal/SelfSigningHandoffTests.swift`
- Modify: `SealTests/Renewal/SelfAppPendingHandoffTests.swift`
- Modify: `Scripts/verify-release-safety.py`

- [ ] **Step 1: 在发布安全脚本中加入结构断言**

加入以下检查：

```python
forbidden_patterns = {
    "Seal/Core/Signing/SigningCoordinator.swift": [
        "for attempt in 1...2",
        "recoverPendingSelfReplacement",
    ],
    "Seal/Core/Renewal/SelfAppRegistrar.swift": [
        "pendingSelfReplacementRecovery",
        "claimAutomaticRecovery",
    ],
}

required_patterns = {
    "Seal/Core/Renewal/SelfReplacementTransactionStore.swift": [
        "claimSubmission",
        "alreadySubmitted",
    ],
    "Seal/Infrastructure/Renewal/AppBundleSigningIdentityReader.swift": [
        "checkMachOCodeSignatures",
        "signerNotAuthorizedByProfile",
    ],
}
```

发现 forbidden 或缺少 required 时脚本退出非零。

- [ ] **Step 2: 删除旧类型，修复所有编译引用**

删除旧 handoff 源码和旧测试。持久文件名仍为 `SelfSigningHandoff.json`，只为兼容现有安装；代码类型全部使用 `SelfReplacementTransactionStore`。

- [ ] **Step 3: 运行搜索检查**

Run:

```bash
rg -n "SelfSigningHandoff|certificateSerialNumbers\.first|recoverPendingSelfReplacement|pendingSelfReplacementRecovery|claimAutomaticRecovery|for attempt in 1\.\.\.2" Seal SealTests
```

Expected: 仅允许新 Store 的 legacy 解码私有结构中出现 `LegacySelfSigningHandoff`；其他无结果。

- [ ] **Step 4: 运行完整自动化验证**

Run:

```bash
python3 Scripts/verify-release-safety.py
xcodegen generate
bash Scripts/ci-test.sh
swift test --package-path Vendor/rork-sign
```

Expected: 三条命令全部退出 0，Swift 单元与 UI 测试无失败。

- [ ] **Step 5: 构建并校验 unsigned IPA**

Run:

```bash
SEAL_IPA_CONFIGURATION=Release SEAL_SKIP_XCODEGEN=1 bash Scripts/build-unsigned-ipa.sh
bash Scripts/verify-ipa.sh build/Seal_*.ipa
```

Expected: 生成一个可校验的 Seal IPA，主 App 和 SealTunnel 均存在，校验脚本退出 0。

- [ ] **Step 6: 提交**

```bash
git add Seal SealTests Scripts/verify-release-safety.py
git commit -m "test: enforce single-submit self renewal invariants"
```

## Task 13：真机闭环验收

**Files:**

- Create: `docs/qa/2026-09-15-self-renewal-device-matrix.md`

- [ ] **Step 1: 建立不包含凭据的验收记录表**

```markdown
| Case | Device | iOS | Initial signer | Slots | Interruption | Result | Transaction ID suffix | Notes |
|---|---|---|---|---|---|---|---|---|
| A1 | iPhone | 17.x | Computer A | A + empty | none |  |  |  |
| A2 | iPad | supported latest | Computer A | A + empty | none |  |  |  |
| B1 | iPhone | supported latest | Computer A | A + C | none |  |  |  |
| C1 | iPhone | supported latest | Local B | B + empty | kill during install |  |  |  |
| C2 | iPhone | supported latest | Local B | B + empty | tunnel loss |  |  |  |
| D1 | iPhone | supported latest | Local B | B + empty | second renewal |  |  |  |
| E1 | iPhone | supported latest | changed/unknown | varies | PC overwrite recovery |  |  |  |
```

不得记录 Apple ID、密码、完整证书序列号、完整设备 UDID 或 P12。

- [ ] **Step 2: 验收空槽位接管**

电脑证书 A 安装 → Seal 创建 B → 安装提交日志只有一次 → 新 Seal 启动显示真实 signer B → A 未撤销 → 数据容器仍在。

- [ ] **Step 3: 验收满槽位接管**

A+C 占满 → 页面明确保护 A → 用户确认 C 的本机关联和其他设备风险 → 撤销 C → 创建 B → 新 Seal 确认 B。若 B 创建失败，确认 A 仍可启动。

- [ ] **Step 4: 验收中断与未知状态**

分别在上传、安装 API 超时、旧进程终止、新进程首次启动前断开通道。每个 transactionID 的安装提交次数必须为 1；部分身份或扩展不一致时进入电脑恢复，不自动重装。

- [ ] **Step 5: 验收连续两轮续签**

完成接管后连续执行两轮续签；证书始终为 B，只更新 profile UUID 和到期时间，第二轮不创建或撤销开发证书。

- [ ] **Step 6: 验收电脑覆盖恢复**

使用与当前安装相同的 Bundle ID、扩展 Bundle ID 和 Team 覆盖安装，不卸载。启动后数据存在、旧事务失去执行权、状态重新识别为外部启动或对应真实身份。

- [ ] **Step 7: 提交验收记录**

```bash
git add docs/qa/2026-09-15-self-renewal-device-matrix.md
git commit -m "docs: record self renewal device acceptance"
```

## 完成定义

只有同时满足以下条件才关闭本批次：

- 代码中不再以描述文件证书数组第一项判断 Seal 实际签名者。
- Seal 每个自替换 transactionID 最多调用一次安装。
- 启动流程没有自动补装入口。
- 新进程以主 App 和全部扩展的真实 CMS signer、Team、Bundle ID、profile UUID 完整确认接管。
- 身份读取不完整时不撤销任何可能维持 Seal 运行的证书。
- 接管失败保留当前可运行身份；无法确认时稳定进入电脑恢复。
- 连续两轮真机续签复用同一张本机证书 B。
- iPhone、iPad和电脑覆盖恢复的验收记录完整。
