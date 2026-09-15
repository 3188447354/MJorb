# Seal 1.0 Onboarding and Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立可跳过、可恢复、按最小条件启用功能的首次引导与统一环境检查，并让用户主动触发 Seal 自续签接管。

**Architecture:** 将现有 `EnvironmentSnapshot` 扩展为不依赖 SwiftUI 的统一 readiness 模型，由独立服务汇总账号、配对、InstallChannel诊断和自管理状态。视图只渲染 readiness 和路由动作，所有签名/安装入口通过同一 Gate判断，避免页面各自猜测环境。

**Tech Stack:** Swift 6、SwiftUI、Swift Testing、Core Data/UserDefaults、现有 PairingStore、InstallChannel、SettingsViewModel、AppsViewModel

**Prerequisite:** 先完成 `2026-09-15-self-renewal-identity-implementation.md`，以复用 `SelfManagementState` 和真实 InstalledIdentity。

---

### Task 1：定义统一环境状态和功能闸门

**Files:**

- Modify: `Seal/Core/Environment/EnvironmentSnapshot.swift`
- Create: `Seal/Core/Environment/EnvironmentFeatureGate.swift`
- Create: `SealTests/Environment/EnvironmentReadinessTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
@Test
func importRemainsAvailableWhenSetupWasSkipped() {
    let readiness = EnvironmentReadiness.fixture(
        account: .needsAction(.addAccount),
        pairing: .needsAction(.importPairing),
        tunnel: .unknown("尚未检查")
    )
    #expect(EnvironmentFeatureGate.evaluate(.importIPA, readiness: readiness) == .allowed)
    #expect(EnvironmentFeatureGate.evaluate(.install, readiness: readiness).isAllowed == false)
}

@Test
func unknownIsNeverTreatedAsReady() {
    let readiness = EnvironmentReadiness.fixture(pairing: .unknown("设备不可达"))
    #expect(readiness.isFullyReady == false)
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/EnvironmentReadinessTests`

Expected: FAIL，新类型不存在。

- [ ] **Step 3: 实现状态和值对象**

```swift
enum ReadinessAction: Equatable, Sendable {
    case acknowledgePrivacy, addAccount, reverifyAccount, importPairing
    case repairPairing, openLocalDevVPN, enableDeveloperMode
    case resolveCertificateCapacity, confirmSelfReplacement, useComputerRecovery
}

enum ReadinessCheck: Equatable, Sendable {
    case ready
    case checking
    case needsAction(ReadinessAction)
    case unknown(String)
}

struct EnvironmentReadiness: Equatable, Sendable {
    let privacy: ReadinessCheck
    let account: ReadinessCheck
    let pairing: ReadinessCheck
    let tunnel: ReadinessCheck
    let developerMode: ReadinessCheck
    let certificateCapacity: ReadinessCheck
    let selfManagement: SelfManagementState

    var isFullyReady: Bool {
        [privacy, account, pairing, tunnel, certificateCapacity].allSatisfy { $0 == .ready }
            && developerMode != .needsAction(.enableDeveloperMode)
            && selfManagement != .recoveryRequired
    }
}

enum EnvironmentFeature: Sendable {
    case browse, importIPA, parseIPA, sign, install, batchRenew, enableSelfRenewal
}

struct FeatureGateDecision: Equatable, Sendable {
    let isAllowed: Bool
    let blockingAction: ReadinessAction?
    let reason: String?
    static let allowed = Self(isAllowed: true, blockingAction: nil, reason: nil)
}
```

`EnvironmentFeatureGate.evaluate` 固定规则：browse/import/parse 永远允许；sign要求 account+certificate；install再要求 pairing+tunnel且 developerMode不是明确失败；batchRenew组合签名和安装；enableSelfRenewal还要求 InstalledIdentity完整且 selfManagement不为 recoveryRequired。

- [ ] **Step 4: 运行测试**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/EnvironmentReadinessTests`

Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Seal/Core/Environment SealTests/Environment/EnvironmentReadinessTests.swift
git commit -m "feat: define environment readiness gates"
```

### Task 2：汇总账号、配对、通道和自管理状态

**Files:**

- Create: `Seal/Core/Environment/EnvironmentReadinessService.swift`
- Modify: `Seal/Features/Settings/SettingsViewModel.swift:160-230,1810-2050`
- Create: `SealTests/Environment/EnvironmentReadinessServiceTests.swift`

- [ ] **Step 1: 写聚合测试**

```swift
@Test
func unreachableDeviceKeepsPairingUnknownInsteadOfDeletingIt() async {
    let service = EnvironmentReadinessService(
        accountProvider: { [.verifiedFixture] },
        pairingProvider: { .validFixture },
        diagnosticsProvider: { .unreachableFixture },
        selfStateProvider: { .externalBootstrap },
        privacyProvider: { true }
    )
    let result = await service.refresh()
    #expect(result.pairing == .unknown("当前无法连接设备验证配对"))
    #expect(result.tunnel == .needsAction(.openLocalDevVPN))
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/EnvironmentReadinessServiceTests`

Expected: FAIL，服务不存在。

- [ ] **Step 3: 实现可注入聚合服务**

```swift
actor EnvironmentReadinessService {
    typealias AccountProvider = @Sendable () async -> [AppleAccountRecord]
    typealias PairingProvider = @Sendable () async throws -> PairingRecord?
    typealias DiagnosticsProvider = @Sendable () async -> InstallChannelDiagnostics
    typealias SelfStateProvider = @Sendable () async -> SelfManagementState

    private func loadPairing() async -> Result<PairingRecord?, Error> {
        do { return .success(try await pairingProvider()) }
        catch { return .failure(error) }
    }

    func refresh() async -> EnvironmentReadiness {
        async let accounts = accountProvider()
        async let pairing = loadPairing()
        async let diagnostics = diagnosticsProvider()
        async let selfState = selfStateProvider()
        return EnvironmentReadinessPolicy.make(
            accounts: await accounts,
            pairing: await pairing,
            diagnostics: await diagnostics,
            selfManagement: await selfState,
            privacyAcknowledged: privacyProvider()
        )
    }
}
```

`EnvironmentReadinessPolicy` 作为同文件纯函数实现。诊断超时只返回 unknown/needsAction，不调用 `PairingStore.delete`，不修改账号状态。

- [ ] **Step 4: SettingsViewModel只发布聚合结果**

加入 `@Published private(set) var environmentReadiness`；现有 `environment` 计算属性暂时桥接到新模型，所有新代码只使用 readiness。`load` 与用户主动检查调用 service，避免重复并发刷新。

- [ ] **Step 5: 运行测试并提交**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/EnvironmentReadinessServiceTests`

Expected: PASS。

```bash
git add Seal/Core/Environment/EnvironmentReadinessService.swift Seal/Features/Settings/SettingsViewModel.swift SealTests/Environment/EnvironmentReadinessServiceTests.swift
git commit -m "feat: aggregate signing environment readiness"
```

### Task 3：持久化可跳过的首次引导进度

**Files:**

- Create: `Seal/Core/Environment/OnboardingProgressStore.swift`
- Create: `SealTests/Environment/OnboardingProgressStoreTests.swift`
- Modify: `Seal/Application/AppContainer.swift`

- [ ] **Step 1: 写持久化测试**

```swift
@Test
func skippingDoesNotMarkEnvironmentReady() async throws {
    let defaults = try #require(UserDefaults(suiteName: "SealOnboarding-\(UUID())"))
    let store = OnboardingProgressStore(defaults: defaults)
    await store.skip()
    #expect(await store.snapshot().hasPresented)
    #expect(await store.snapshot().wasSkipped)
    #expect(await store.snapshot().completedSteps.isEmpty)
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/OnboardingProgressStoreTests`

Expected: FAIL，Store不存在。

- [ ] **Step 3: 实现最小持久模型**

```swift
struct OnboardingProgress: Codable, Equatable, Sendable {
    var hasPresented = false
    var wasSkipped = false
    var privacyAcknowledged = false
    var completedSteps: Set<String> = []
}

actor OnboardingProgressStore {
    private let defaults: UserDefaults
    private let key = "seal.onboarding.v1"

    func snapshot() -> OnboardingProgress { load() }
    func skip() { mutate { $0.hasPresented = true; $0.wasSkipped = true } }
    func acknowledgePrivacy() { mutate { $0.privacyAcknowledged = true } }
    func finishPresentation() { mutate { $0.hasPresented = true; $0.wasSkipped = false } }
}
```

`mutate` 必须编码完整值后一次 `set`；不存储密码、UDID、证书或诊断文本。

- [ ] **Step 4: 注入 AppContainer并运行测试**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/OnboardingProgressStoreTests`

Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Seal/Core/Environment/OnboardingProgressStore.swift Seal/Application/AppContainer.swift SealTests/Environment/OnboardingProgressStoreTests.swift
git commit -m "feat: persist skippable onboarding progress"
```

### Task 4：实现首次引导和首页环境卡

**Files:**

- Create: `Seal/Features/Onboarding/OnboardingFlowView.swift`
- Create: `Seal/Features/Onboarding/OnboardingViewModel.swift`
- Modify: `Seal/Features/Apps/EnvironmentStatusGlass.swift`
- Modify: `Seal/Features/Apps/AppsRootView.swift:1-180`
- Create: `SealTests/Environment/OnboardingPresentationTests.swift`

- [ ] **Step 1: 写文案与路由测试**

```swift
@Test(arguments: [
    OnboardingCase(.addAccount, "添加 Apple ID", SettingsRoute.account),
    OnboardingCase(.importPairing, "导入设备配对", SettingsRoute.pairing),
    OnboardingCase(.openLocalDevVPN, "打开 LocalDevVPN", SettingsRoute.localDevVPN),
    OnboardingCase(.resolveCertificateCapacity, "处理证书槽位", SettingsRoute.certificates)
])
func actionMapsToOneRoute(testCase: OnboardingCase) {
    #expect(OnboardingPresentation(testCase.action).title == testCase.title)
    #expect(OnboardingPresentation(testCase.action).route == testCase.route)
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/OnboardingPresentationTests`

Expected: FAIL，展示模型不存在。

- [ ] **Step 3: 实现页面，不复制业务判断**

`OnboardingViewModel` 只暴露 `progress`、`readiness`、`primaryAction`、`skip()` 和 `refresh()`。`OnboardingFlowView` 包含说明、当前步骤、稍后设置和重新检查；所有设置跳转经现有 SettingsRoute。

`EnvironmentStatusGlass` 改为读取 `EnvironmentReadiness`：主文案显示第一个阻断项，展开区域显示全部检查项；unknown使用“无法确认”而不是红色失败。

- [ ] **Step 4: 用户主动开启自续签**

只有 gate 返回 allowed 时展示：

```swift
Button("开启 Seal 自续签") {
    Task { await viewModel.beginSelfManagementTakeover() }
}
.disabled(viewModel.selfRenewalGate.isAllowed == false)
```

添加账号成功事件只触发 `refresh()`，不得调用 begin takeover、创建证书或安装。

- [ ] **Step 5: 运行测试并提交**

Run:

```bash
bash Scripts/ci-test.sh \
  -only-testing:SealTests/OnboardingPresentationTests \
  -only-testing:SealTests/EnvironmentReadinessTests
```

Expected: PASS。

```bash
git add Seal/Features/Onboarding Seal/Features/Apps/EnvironmentStatusGlass.swift Seal/Features/Apps/AppsRootView.swift SealTests/Environment/OnboardingPresentationTests.swift
git commit -m "feat: add skippable Seal onboarding"
```

### Task 5：统一签名、安装和一键续签入口的阻断行为

**Files:**

- Modify: `Seal/Features/Apps/AppsViewModel.swift`
- Modify: `Seal/Features/Apps/AppSigningSheet.swift`
- Modify: `Seal/Features/Apps/AppsRootView.swift`
- Create: `SealTests/Environment/EnvironmentGateIntegrationTests.swift`

- [ ] **Step 1: 写入口一致性测试**

```swift
@Test
func everyInstallEntryUsesSameBlockingAction() async {
    let fixture = AppsViewModelFixture.readinessMissingPairing()
    await fixture.viewModel.beginInstall(appID: fixture.app.id)
    #expect(fixture.viewModel.alertFailure?.code == "SEAL-ENV-PAIRING")
    await fixture.viewModel.beginBatchRefresh()
    #expect(fixture.viewModel.alertFailure?.code == "SEAL-ENV-PAIRING")
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/EnvironmentGateIntegrationTests`

Expected: FAIL，入口仍分别判断。

- [ ] **Step 3: 所有入口调用同一 Gate**

在 AppsViewModel集中实现：

```swift
private func requireEnvironment(_ feature: EnvironmentFeature) throws {
    let decision = EnvironmentFeatureGate.evaluate(feature, readiness: environmentReadiness)
    guard decision.isAllowed else {
        throw EnvironmentFailure.make(decision)
    }
}
```

导入不调用 gate；签名调用 `.sign`；安装调用 `.install`；一键续签调用 `.batchRenew`。View只根据同一 decision显示禁用原因和修复入口。

- [ ] **Step 4: 回归测试并提交**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/EnvironmentGateIntegrationTests`

Expected: PASS。

```bash
git add Seal/Features/Apps/AppsViewModel.swift Seal/Features/Apps/AppSigningSheet.swift Seal/Features/Apps/AppsRootView.swift SealTests/Environment/EnvironmentGateIntegrationTests.swift
git commit -m "refactor: enforce shared environment gates"
```

### Task 6：UI回归和发布门

**Files:**

- Create: `SealUITests/OnboardingFlowUITests.swift`
- Modify: `Scripts/verify-release-safety.py`

- [ ] **Step 1: 添加UI流程**

```swift
func testSkipOnboardingKeepsImportEnabledAndInstallBlocked() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test", "--fresh-onboarding", "--environment-missing"]
    app.launch()
    app.buttons["稍后设置"].tap()
    XCTAssertTrue(app.buttons["import-toolbar-button"].isEnabled)
    XCTAssertTrue(app.otherElements["environment-status-glass"].exists)
}
```

再增加“完成配对后状态卡前进到账号”和“添加账号后不会自动弹出自安装”的UI用例。

- [ ] **Step 2: 发布脚本断言没有添加账号即自动接管**

`verify-release-safety.py` 检查账号保存函数中不存在 `beginSelfManagementTakeover` 或直接 `install` 调用，并要求 `EnvironmentFeatureGate` 存在。

- [ ] **Step 3: 全量验证**

Run:

```bash
python3 Scripts/verify-release-safety.py
xcodegen generate
bash Scripts/ci-test.sh
```

Expected: 脚本和全部测试退出0。

- [ ] **Step 4: 提交**

```bash
git add SealUITests/OnboardingFlowUITests.swift Scripts/verify-release-safety.py
git commit -m "test: cover onboarding environment flow"
```
