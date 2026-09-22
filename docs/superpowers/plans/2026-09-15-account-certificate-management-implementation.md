# Seal 1.0 Account and Certificate Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让多免费 Apple ID、会话恢复、App账号绑定、证书角色、撤销和删除操作形成安全闭环，确保 Seal当前身份和未结算事务永远不会被普通管理操作破坏。

**Architecture:** 将认证恢复、账号删除、证书角色和证书操作分别建成纯策略与协调器；SettingsViewModel只编排服务并发布展示模型。所有破坏性动作使用执行前新快照，删除本机材料和撤销远端证书保持两个接口。

**Tech Stack:** Swift 6、Swift Testing、SwiftUI、Keychain、AltSign、现有 AppleAccountClient、ApplePortalInventoryService、ApplePortalCertificateService、AppStore

**Prerequisite:** 自续签身份计划中的真实 InstalledIdentity、SelfReplacementTransactionStore和 CertificateTakeoverPolicy先完成。

---

### Task 1：统一账号状态和认证失败分类

**Files:**

- Modify: `Seal/Core/Accounts/AccountStatus.swift`
- Modify: `Seal/Core/Accounts/AccountAvailabilityPolicy.swift`
- Create: `Seal/Core/Accounts/AccountAuthenticationFailurePolicy.swift`
- Create: `SealTests/Accounts/AccountAuthenticationFailurePolicyTests.swift`

- [ ] **Step 1: 写网络与会话错误不可混淆测试**

```swift
@Test(arguments: [
    AuthCase(code: "1100", result: AccountAuthenticationFailureKind.sessionExpired),
    AuthCase(code: "-1009", result: AccountAuthenticationFailureKind.temporaryUnavailable),
    AuthCase(code: "-1001", result: AccountAuthenticationFailureKind.temporaryUnavailable),
    AuthCase(code: "2FA_REQUIRED", result: AccountAuthenticationFailureKind.userVerificationRequired)
])
func classifiesAuthenticationFailure(testCase: AuthCase) {
    #expect(AccountAuthenticationFailurePolicy.classify(code: testCase.code) == testCase.result)
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/AccountAuthenticationFailurePolicyTests`

Expected: FAIL，策略不存在。

- [ ] **Step 3: 扩展状态并实现纯策略**

```swift
enum AccountStatus: String, Codable, Sendable {
    case verified
    case availableOffline
    case needsVerification // 只为旧持久化数据保留，由修复策略迁出
    case sessionExpired
    case credentialsMissing
    case teamUnavailable
}

enum AccountAuthenticationFailureKind: Equatable, Sendable {
    case sessionExpired
    case temporaryUnavailable
    case userVerificationRequired
    case credentialsRejected
}

enum AuthenticationRecoveryRequirement: Equatable, Sendable {
    case none, retryLater, automaticRelogin, userVerificationRequired
}
```

明确 Apple 1100/认证令牌失效映射 automaticRelogin；网络断开、超时、Apple 5xx映射 retryLater且不持久化降级账号；2FA映射 userVerificationRequired。`AccountStatus` 只保存稳定状态，临时网络故障只存在于本次操作结果中。

- [ ] **Step 4: 运行现有账号状态迁移测试**

Run:

```bash
bash Scripts/ci-test.sh \
  -only-testing:SealTests/AccountAuthenticationFailurePolicyTests \
  -only-testing:SealTests/AccountAvailabilityPolicyTests
```

Expected: PASS；旧 `.availableOffline`、`.needsVerification` raw value仍可解码。`AccountAvailabilityPolicy.repairedStatus` 再根据 `verificationFailureReason` 与本机 secret映射：sessionExpired→`.sessionExpired`，凭据拒绝/缺失/不匹配→`.credentialsMissing`，nil且有secret→`.availableOffline`，nil且无secret→`.credentialsMissing`；迁移前后都不能崩溃。

- [ ] **Step 5: 提交**

```bash
git add Seal/Core/Accounts/AccountStatus.swift Seal/Core/Accounts/AccountAvailabilityPolicy.swift Seal/Core/Accounts/AccountAuthenticationFailurePolicy.swift SealTests/Accounts/AccountAuthenticationFailurePolicyTests.swift
git commit -m "feat: classify Apple account availability"
```

### Task 2：会话过期先自动重新登录并保留签名材料

**Files:**

- Create: `Seal/Core/Accounts/AccountReauthenticationCoordinator.swift`
- Modify: `Seal/Infrastructure/Accounts/AppleAccountClient.swift`
- Modify: `Seal/Core/Accounts/AccountSecret.swift`
- Create: `SealTests/Accounts/AccountReauthenticationCoordinatorTests.swift`

- [ ] **Step 1: 写成功合并与2FA暂停测试**

```swift
@Test
func automaticReloginReplacesTokenButPreservesEveryP12() async throws {
    let old = AccountSecret.fixture(password: "saved", p12BySerial: ["A": Data([1]), "B": Data([2])])
    let client = FakeAccountAuthenticator(result: .success(.fixture(authToken: "new")))
    let coordinator = AccountReauthenticationCoordinator(authenticator: client)
    let result = await coordinator.attempt(old)
    guard case let .recovered(secret) = result else {
        Issue.record("expected automatic recovery")
        return
    }
    #expect(secret.authToken == "new")
    #expect(secret.p12(for: "A") == Data([1]))
    #expect(secret.p12(for: "B") == Data([2]))
}

@Test
func twoFactorDoesNotDestroyOldSecret() async throws {
    let old = AccountSecret.fixture(password: "saved", p12BySerial: ["B": Data([2])])
    let coordinator = AccountReauthenticationCoordinator(authenticator: FakeAccountAuthenticator(result: .twoFactorRequired))
    let result = await coordinator.attempt(old)
    #expect(result == .requiresUserVerification(existingSecret: old))
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/AccountReauthenticationCoordinatorTests`

Expected: FAIL，协调器不存在。

- [ ] **Step 3: 实现一次自动尝试**

```swift
protocol AccountAuthenticating: Sendable {
    func login(email: String, password: String) async throws -> AccountSecret
}

actor AccountReauthenticationCoordinator {
    func attempt(_ existing: AccountSecret) async -> AccountReauthenticationResult {
        guard let password = existing.password, password.isEmpty == false else {
            return .requiresUserVerification(existingSecret: existing)
        }
        do {
            let fresh = try await authenticator.login(email: existing.email, password: password)
            return .recovered(secret: fresh.preservingSigningMaterial(from: existing))
        } catch {
            return policy.result(for: error, existingSecret: existing)
        }
    }
}
```

每次用户动作最多自动登录一次；2FA、密码错误或再次1100转用户验证，不循环。只有 fresh登录完整成功后才写 Keychain；写入失败保留 existing。

- [ ] **Step 4: 接入 AppleAccountClient验证路径**

现有 `validate` 收到明确 sessionExpired时调用协调器；网络错误原样返回 temporaryUnavailable。重新验证成功后刷新远端证书清单，再恢复原任务游标。

- [ ] **Step 5: 运行测试并提交**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/AccountReauthenticationCoordinatorTests`

Expected: PASS。

```bash
git add Seal/Core/Accounts/AccountReauthenticationCoordinator.swift Seal/Infrastructure/Accounts/AppleAccountClient.swift Seal/Core/Accounts/AccountSecret.swift SealTests/Accounts/AccountReauthenticationCoordinatorTests.swift
git commit -m "feat: recover expired Apple sessions locally"
```

### Task 3：固定App账号绑定与账号迁移规则

**Files:**

- Create: `Seal/Core/Accounts/AppAccountBindingPolicy.swift`
- Modify: `Seal/Core/Signing/SigningCertificateSelectionPolicy.swift`
- Modify: `Seal/Features/Apps/AppsViewModel.swift`
- Modify: `Seal/Core/Apps/AppRecord.swift`
- Modify: `Seal/Infrastructure/Persistence/CoreDataModel.swift`
- Modify: `Seal/Infrastructure/Persistence/CoreDataAppStore.swift`
- Modify: `SealTests/Persistence/CoreDataAppStoreTests.swift`
- Create: `SealTests/Accounts/AppAccountBindingPolicyTests.swift`

- [ ] **Step 1: 写默认账号不覆盖既有绑定测试**

```swift
@Test
func existingBindingWinsOverChangedDefaultAccount() throws {
    let bound = UUID()
    let changedDefault = UUID()
    #expect(try AppAccountBindingPolicy.accountID(
        app: .fixture(accountID: bound),
        availableAccountIDs: [bound, changedDefault],
        defaultAccountID: changedDefault
    ) == bound)
}

@Test
func deletedBindingDoesNotSilentlyFallback() {
    let app = AppRecord.fixture(accountID: UUID())
    #expect(throws: AppAccountBindingFailure.boundAccountMissing) {
        try AppAccountBindingPolicy.accountID(app: app, availableAccountIDs: [], defaultAccountID: UUID())
    }
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/AppAccountBindingPolicyTests`

Expected: FAIL，策略不存在。

- [ ] **Step 3: 实现绑定策略**

```swift
enum AppAccountBindingPolicy {
    static func accountID(
        app: AppRecord,
        availableAccountIDs: Set<UUID>,
        defaultAccountID: UUID?
    ) throws -> UUID {
        if let bound = app.accountID {
            guard availableAccountIDs.contains(bound) else { throw AppAccountBindingFailure.boundAccountMissing }
            return bound
        }
        guard app.state != .installed, app.isSeal == false, let defaultAccountID else {
            throw AppAccountBindingFailure.explicitSelectionRequired
        }
        return defaultAccountID
    }
}
```

迁移账号时先把可选 `pendingAccountMigrationID` 写入 `AppRecord` 和 Core Data，用新账号签名并成功覆盖安装后才写 `accountID`；失败清除 pending，保留旧绑定。为旧模型增加 legacy 快照和 SQLite轻量迁移测试，旧记录解码后 pending必须为 nil。Seal迁移直接调用 SelfReplacementCoordinator。

- [ ] **Step 4: 运行测试并提交**

Run:

```bash
bash Scripts/ci-test.sh \
  -only-testing:SealTests/AppAccountBindingPolicyTests \
  -only-testing:SealTests/SigningCertificateSelectionPolicyTests \
  -only-testing:SealTests/CoreDataAppStoreTests
```

Expected: PASS。

```bash
git add Seal/Core/Accounts/AppAccountBindingPolicy.swift Seal/Core/Signing/SigningCertificateSelectionPolicy.swift Seal/Features/Apps/AppsViewModel.swift Seal/Core/Apps/AppRecord.swift Seal/Infrastructure/Persistence/CoreDataModel.swift Seal/Infrastructure/Persistence/CoreDataAppStore.swift SealTests/Persistence/CoreDataAppStoreTests.swift SealTests/Accounts/AppAccountBindingPolicyTests.swift
git commit -m "feat: lock managed apps to signing accounts"
```

### Task 4：阻止删除Seal账号或事务账号

**Files:**

- Create: `Seal/Core/Accounts/AccountDeletionPolicy.swift`
- Modify: `Seal/Features/Settings/SettingsViewModel.swift:1621-1675`
- Create: `SealTests/Accounts/AccountDeletionPolicyTests.swift`

- [ ] **Step 1: 写删除决策测试**

```swift
@Test
func blocksSealAndPendingTransactionAccounts() {
    let account = UUID()
    #expect(AccountDeletionPolicy.evaluate(accountID: account, sealAccountID: account, transactionAccountIDs: []) == .blocked(.sealDependsOnAccount))
    #expect(AccountDeletionPolicy.evaluate(accountID: account, sealAccountID: nil, transactionAccountIDs: [account]) == .blocked(.transactionInProgress))
}

@Test
func ordinaryBindingsRequireConfirmationWithoutChangingBinding() {
    let account = UUID()
    #expect(AccountDeletionPolicy.evaluate(accountID: account, sealAccountID: nil, transactionAccountIDs: [], ordinaryAppCount: 2) == .confirmOrdinaryApps(count: 2))
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/AccountDeletionPolicyTests`

Expected: FAIL，删除策略不存在。

- [ ] **Step 3: 实现删除快照和策略**

```swift
enum AccountDeletionBlocker: Equatable, Sendable { case sealDependsOnAccount, transactionInProgress, keychainUnreadable }
enum AccountDeletionDecision: Equatable, Sendable {
    case allowed
    case confirmOrdinaryApps(count: Int)
    case blocked(AccountDeletionBlocker)
}
```

SettingsViewModel删除前读取真实 Seal绑定、SelfReplacement与BatchRenewal未结算账号、普通 App数量和 Keychain快照。blocked不显示破坏性按钮；普通 App确认后删除账号但保留 App.accountID，界面显示“原账号已删除”。

- [ ] **Step 4: 确保不调用远端撤销**

删除协调器依赖 AccountRepository和KeychainVault，不注入 ApplePortalCertificateService。失败时恢复账号记录和原 Keychain secret；回滚失败显示明确数据状态，不谎报删除成功。

- [ ] **Step 5: 运行测试并提交**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/AccountDeletionPolicyTests`

Expected: PASS。

```bash
git add Seal/Core/Accounts/AccountDeletionPolicy.swift Seal/Features/Settings/SettingsViewModel.swift SealTests/Accounts/AccountDeletionPolicyTests.swift
git commit -m "fix: protect accounts used by Seal transactions"
```

### Task 5：建立证书角色和本机关联展示模型

**Files:**

- Create: `Seal/Core/Signing/CertificateRole.swift`
- Create: `Seal/Core/Signing/CertificateAssociationSnapshot.swift`
- Modify: `Seal/Features/Settings/SettingsViewModel.swift:580-760,1200-1320`
- Create: `SealTests/Settings/CertificateRoleTests.swift`

- [ ] **Step 1: 写角色来源测试**

```swift
@Test
func actualSignerAndAuthorizedCertificateAreNotConfused() {
    let result = CertificateRolePolicy.roles(
        serialNumber: "A",
        actualSealSigner: "B",
        profileAuthorizedSerials: ["A", "B"],
        localPrivateKeySerials: ["B"],
        association: .confirmed(bundleIDs: ["com.example.app"])
    )
    #expect(result.contains(.currentSealSigner) == false)
    #expect(result.contains(.profileAuthorized))
}

@Test
func failedDeviceReadProducesUnknownNotNoAssociation() {
    let failure = DeviceProfileReadFailure.channelUnavailable
    #expect(CertificateAssociationPolicy.make(deviceProfiles: .failure(failure)) == .unknown)
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/CertificateRoleTests`

Expected: FAIL，角色模型不存在。

- [ ] **Step 3: 实现证书角色**

```swift
enum CertificateRole: String, Hashable, Sendable {
    case currentSealSigner
    case locallyUsable
    case external
    case profileAuthorized
    case associatedOnThisDevice
    case associationUnknown
    case expired
}

enum CertificateAssociationSnapshot: Equatable, Sendable {
    case confirmed(bundleIDs: [String])
    case possible(bundleIDs: [String])
    case none
    case unknown
}

enum DeviceProfileReadFailure: Error, Equatable, Sendable {
    case channelUnavailable
    case malformedResponse
}
```

SettingsViewModel一次刷新收集：远端证书、Keychain P12、真实 InstalledIdentity、设备 profiles、Seal AppStore记录。只在设备读取完整且确无引用时返回 none；非 Seal管理 App以 Bundle ID显示“其他来源”。

- [ ] **Step 4: 运行测试并提交**

Run:

```bash
bash Scripts/ci-test.sh \
  -only-testing:SealTests/CertificateRoleTests \
  -only-testing:SealTests/CertificateRevocationImpactTests
```

Expected: PASS。

```bash
git add Seal/Core/Signing/CertificateRole.swift Seal/Core/Signing/CertificateAssociationSnapshot.swift Seal/Features/Settings/SettingsViewModel.swift SealTests/Settings/CertificateRoleTests.swift
git commit -m "feat: explain certificate roles and local associations"
```

### Task 6：分离远端撤销与本机材料删除

**Files:**

- Create: `Seal/Core/Signing/CertificateOperationPolicy.swift`
- Modify: `Seal/Features/Settings/SettingsViewModel.swift:422-575,663-880,2318-2345`
- Modify: `Seal/Infrastructure/Security/KeychainVault.swift`
- Create: `SealTests/Settings/CertificateOperationPolicyTests.swift`

- [ ] **Step 1: 写操作边界测试**

```swift
@Test
func currentSealSignerCannotBeRevokedOrRemovedLocally() {
    let context = CertificateOperationContext.fixture(isCurrentSealSigner: true)
    #expect(CertificateOperationPolicy.evaluate(.revokeRemote, context: context).isAllowed == false)
    #expect(CertificateOperationPolicy.evaluate(.removeLocalMaterial, context: context).isAllowed == false)
}

@Test
func removingLocalMaterialNeverRequestsRemoteMutation() {
    let context = CertificateOperationContext.fixture(isCurrentSealSigner: false, hasLocalKey: true)
    #expect(CertificateOperationPolicy.evaluate(.removeLocalMaterial, context: context) == .allowed(.localOnly))
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/CertificateOperationPolicyTests`

Expected: FAIL，操作策略不存在。

- [ ] **Step 3: 实现两个明确动作**

```swift
enum CertificateOperation: Sendable { case revokeRemote, removeLocalMaterial }
enum CertificateMutationScope: Sendable { case remoteThenLocal, localOnly }
enum CertificateOperationBlocker: Equatable, Sendable {
    case currentSealSigner, pendingTransaction, associationUnknown, noLocalMaterial
}
enum CertificateOperationDecision: Equatable, Sendable {
    case allowed(CertificateMutationScope)
    case blocked(CertificateOperationBlocker)

    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}
struct CertificateOperationContext: Sendable {
    let isCurrentSealSigner: Bool
    let isReferencedByPendingTransaction: Bool
    let associationIsKnown: Bool
    let hasLocalKey: Bool
}
```

`revokeRemoteCertificate` 必须执行前刷新真实身份和远端清单，Apple撤销成功后才删除该 serial本机材料。`removeLocalCertificateMaterial` 只调用 `AccountSecret.removeStoredCertificateMaterial`和Keychain保存，不注入或调用 Portal服务。

- [ ] **Step 4: 删除危险的整账号清证书入口**

现有 `resetCertificate` 改为按序列号本机删除，并受策略保护；不再调用 `clearSigningMaterial(accountID:)`清空全部历史材料。批量清理必须逐序列号显示影响和确认。

- [ ] **Step 5: 运行测试并提交**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/CertificateOperationPolicyTests`

Expected: PASS。

```bash
git add Seal/Core/Signing/CertificateOperationPolicy.swift Seal/Features/Settings/SettingsViewModel.swift Seal/Infrastructure/Security/KeychainVault.swift SealTests/Settings/CertificateOperationPolicyTests.swift
git commit -m "refactor: separate local and remote certificate removal"
```

### Task 7：把安全接管决策接入证书页

**Files:**

- Modify: `Seal/Core/Signing/CertificateTakeoverPolicy.swift`
- Modify: `Seal/Features/Settings/SigningCertificateSettingsView.swift`
- Modify: `Seal/Features/Settings/SettingsViewModel.swift`
- Create: `SealTests/Settings/CertificateTakeoverFlowTests.swift`

- [ ] **Step 1: 写A、A+C和未知A流程测试**

```swift
@Test
func fullSlotsProtectAAndCreateBAfterConfirmedCRevocation() async throws {
    let fixture = CertificateTakeoverFixture(remote: ["A", "C"], actualSigner: "A")
    #expect(await fixture.coordinator.prepare() == .needsConfirmation(serials: ["C"]))
    try await fixture.coordinator.confirmAndContinue(serial: "C")
    #expect(await fixture.portal.revokedSerials == ["C"])
    #expect(await fixture.portal.createdCount == 1)
    #expect(await fixture.portal.revokedSerials.contains("A") == false)
}

@Test
func unknownActualSignerBlocksWithoutPortalMutation() async {
    let fixture = CertificateTakeoverFixture(remote: ["A", "C"], actualSigner: nil)
    #expect(await fixture.coordinator.prepare().isBlocked)
    #expect(await fixture.portal.mutationCount == 0)
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/CertificateTakeoverFlowTests`

Expected: FAIL，Settings流程仍使用旧清理逻辑。

- [ ] **Step 3: 执行前重新取证**

确认页保存的只是候选序列号。用户确认后重新读取 remote inventory、actual Seal signer、本机私钥和本机关联；C不再满足条件则取消。撤销C成功后刷新确认空位，再创建B并验证P12；B失败只报告失败，不清除A。

- [ ] **Step 4: 更新页面角色和警告**

页面顶部显示 Seal自管理状态；证书卡片展示角色标签、完整序列号、本机关联和“其他设备未知”。A隐藏普通撤销按钮；associationUnknown禁止批量自动清理。

- [ ] **Step 5: 运行测试并提交**

Run:

```bash
bash Scripts/ci-test.sh \
  -only-testing:SealTests/CertificateTakeoverFlowTests \
  -only-testing:SealTests/CertificateCleanupPolicyTests
```

Expected: PASS。

```bash
git add Seal/Core/Signing/CertificateTakeoverPolicy.swift Seal/Features/Settings/SigningCertificateSettingsView.swift Seal/Features/Settings/SettingsViewModel.swift SealTests/Settings/CertificateTakeoverFlowTests.swift
git commit -m "feat: close certificate takeover flow"
```

### Task 8：账号证书UI与全量安全门

**Files:**

- Modify: `Seal/Features/Settings/CertificatesRootView.swift`
- Modify: `Seal/Features/Settings/SigningCertificateSettingsView.swift`
- Create: `SealUITests/AccountCertificateUITests.swift`
- Modify: `Scripts/verify-release-safety.py`

- [ ] **Step 1: 添加关键UI测试**

```swift
func testSealAccountCannotBeDeleted() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test", "--seal-account-bound"]
    app.launch()
    app.buttons["settings-accounts"].tap()
    app.buttons["account-actions"].tap()
    XCTAssertFalse(app.buttons["delete-account"].isEnabled)
    XCTAssertTrue(app.staticTexts["请先切换 Seal 签名账号或使用电脑恢复"].exists)
}
```

再覆盖：会话过期自动恢复、2FA提示、本地删除不触发撤销、A受保护、关联unknown文案。

- [ ] **Step 2: 增加发布脚本安全断言**

禁止账号删除路径引用 `revokeCertificate`；禁止 `resetCertificate`调用 `clearSigningMaterial`；要求所有撤销入口调用 `CertificateOperationPolicy`并读取真实 InstalledIdentity。

- [ ] **Step 3: 全量验证**

Run:

```bash
python3 Scripts/verify-release-safety.py
xcodegen generate
bash Scripts/ci-test.sh
```

Expected: 全部退出0。

- [ ] **Step 4: 提交**

```bash
git add Seal/Features/Settings/CertificatesRootView.swift Seal/Features/Settings/SigningCertificateSettingsView.swift SealUITests/AccountCertificateUITests.swift Scripts/verify-release-safety.py
git commit -m "test: enforce account and certificate safety"
```
