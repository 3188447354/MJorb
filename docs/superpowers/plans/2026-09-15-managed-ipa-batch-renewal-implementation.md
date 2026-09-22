# Seal 1.0 Managed IPA and Batch Renewal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让所有本机已安装且由 Seal管理的普通 App按原账号分组完成一次主动一键续签，并在普通 App结束后把 Seal作为最后一个跨进程任务处理。

**Architecture:** 在现有 RefreshQueue之上建立版本化 `BatchRenewalTransaction`，把候选快照、账号分组、游标和“安装可能已提交”状态持久化。纯策略负责候选、排序和故障作用域，Runner顺序执行副作用；普通 App沿用 SigningCoordinator，Seal委托 SelfReplacementTransaction。

**Tech Stack:** Swift 6、Swift Testing、SwiftUI、Core Data、ZIPFoundation、现有 AppStore、RenewalCoordinator、SigningCoordinator、InstallChannel

**Prerequisites:** 先完成自续签身份计划、账号证书计划和环境检查计划；本计划复用真实 Seal身份、账号状态及 EnvironmentFeatureGate。

---

### Task 1：统一设备现实与 Seal管理状态

**Files:**

- Create: `Seal/Core/Apps/ManagedInstallationState.swift`
- Modify: `Seal/Features/Apps/InstalledAppDeviceVerifier.swift`
- Modify: `Seal/Core/Apps/AppRecord.swift`
- Modify: `Seal/Infrastructure/Persistence/CoreDataModel.swift`
- Modify: `Seal/Infrastructure/Persistence/CoreDataAppStore.swift`
- Modify: `SealTests/Persistence/CoreDataAppStoreTests.swift`
- Create: `SealTests/Apps/ManagedInstallationStateTests.swift`

- [ ] **Step 1: 写状态判定测试**

```swift
@Test
func positiveMismatchMarksExternalChangeButMissingEvidenceDoesNot() {
    let snapshot = ManagedInstallSnapshot.fixture(version: "2", profileUUID: "NEW")
    let record = AppRecord.fixture(version: "1", profileUUID: "OLD")
    #expect(ManagedInstallationPolicy.evaluate(record: record, snapshot: .found(snapshot)) == .installedExternallyChanged)
    #expect(ManagedInstallationPolicy.evaluate(record: record, snapshot: .unavailable) == .stateUnknown)
}

@Test
func missingOriginalIPAIsNotRenewable() {
    let state = ManagedInstallationState.installedManaged(source: .missing)
    #expect(state.isBatchRenewable == false)
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/ManagedInstallationStateTests`

Expected: FAIL，新状态不存在。

- [ ] **Step 3: 实现状态和值对象**

```swift
enum ManagedSourceState: String, Codable, Sendable { case available, missing, unreadable }

enum ManagedInstallationState: Equatable, Sendable {
    case imported
    case signed
    case installedManaged(source: ManagedSourceState)
    case installedExternallyChanged
    case notInstalled
    case stateUnknown

    var isBatchRenewable: Bool {
        self == .installedManaged(source: .available)
    }
}

enum DeviceInstallEvidence: Equatable, Sendable {
    case found(ManagedInstallSnapshot)
    case absent
    case unavailable
}
```

`ManagedInstallationPolicy.evaluate` 只有在设备返回明确版本/Team/profile/映射 Bundle差异时返回 external；`.unavailable` 一律 unknown。`AppRecord`增加可迁移的 `managementStatusRaw`、`externalChangeReason` 和一次性 `externalTakeoverAuthorizationID`，旧数据按现有状态推导，不改原始 IPA路径。

在 `CoreDataModel.make()` 增加对应可选属性；把实施当时的旧 `make()` 完整冻结为下一个 legacy model，并加入 `candidateLegacyModels`。`CoreDataAppStore.write/decode` 双向映射三个字段，迁移测试要用旧 SQLite 打开并断言旧 App可读取、状态按旧字段推导、授权 ID为空。若账号计划已先增加模型版本，本任务基于其最新模型顺延版本号，不能覆盖已有 legacy 定义。

- [ ] **Step 4: InstalledAppDeviceVerifier返回证据而不是Bool**

将 `verify` 结果改成 `DeviceInstallEvidence`；设备查询失败不再写 `notInstalled`。调用方只在 `.absent` 时标记未安装。

- [ ] **Step 5: 运行测试并提交**

Run:

```bash
bash Scripts/ci-test.sh \
  -only-testing:SealTests/ManagedInstallationStateTests \
  -only-testing:SealTests/SignedArtifactSnapshotTests \
  -only-testing:SealTests/CoreDataAppStoreTests
```

Expected: PASS。

```bash
git add Seal/Core/Apps/ManagedInstallationState.swift Seal/Core/Apps/AppRecord.swift Seal/Features/Apps/InstalledAppDeviceVerifier.swift Seal/Infrastructure/Persistence/CoreDataModel.swift Seal/Infrastructure/Persistence/CoreDataAppStore.swift SealTests/Persistence/CoreDataAppStoreTests.swift SealTests/Apps/ManagedInstallationStateTests.swift
git commit -m "feat: model managed installation reality"
```

### Task 2：生成“所有已管理已安装App”的不可变批次计划

**Files:**

- Create: `Seal/Core/Renewal/BatchRenewalPlan.swift`
- Modify: `Seal/Core/Renewal/RefreshPlanner.swift`
- Create: `SealTests/Renewal/BatchRenewalPlanTests.swift`

- [ ] **Step 1: 写候选和排序测试**

```swift
@Test
func includesAllManagedInstalledAppsAndAlwaysPlacesSealLast() throws {
    let accountA = UUID()
    let accountB = UUID()
    let apps = [
        AppRecord.fixture(name: "B", accountID: accountB, managed: true),
        AppRecord.fixture(name: "Seal", accountID: accountA, managed: true, isSeal: true),
        AppRecord.fixture(name: "A", accountID: accountA, managed: true),
        AppRecord.fixture(name: "Removed", accountID: accountA, managed: false)
    ]
    let plan = BatchRenewalPlanner.make(apps: apps, defaultAccountID: accountA)
    #expect(plan.items.map(\.name) == ["A", "B", "Seal"])
    #expect(plan.items.last?.isSeal == true)
}
```

另测所有候选均纳入而不检查到期日；sourceMissing/externalChanged/unknown出现在 exclusions并带原因。

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/BatchRenewalPlanTests`

Expected: FAIL，新 planner不存在。

- [ ] **Step 3: 实现不可变计划**

```swift
struct BatchRenewalPlan: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        let appID: UUID
        let accountID: UUID
        let name: String
        let isSeal: Bool
        let stableOrder: String
    }
    struct Exclusion: Codable, Equatable, Sendable {
        let appID: UUID
        let name: String
        let reason: String
    }
    let items: [Item]
    let exclusions: [Exclusion]
}
```

排序：默认账号普通 App、其他账号按账号 UUID、组内按小写显示名+App UUID；所有普通 App之后单独追加 Seal。App已有绑定缺失时排除，不回退默认账号。

- [ ] **Step 4: 运行测试并提交**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/BatchRenewalPlanTests`

Expected: PASS。

```bash
git add Seal/Core/Renewal/BatchRenewalPlan.swift Seal/Core/Renewal/RefreshPlanner.swift SealTests/Renewal/BatchRenewalPlanTests.swift
git commit -m "feat: plan all managed apps for renewal"
```

### Task 3：建立可恢复的批量续签事务

**Files:**

- Create: `Seal/Core/Renewal/BatchRenewalTransaction.swift`
- Modify: `Seal/Infrastructure/Renewal/RefreshQueueStore.swift`
- Modify: `SealTests/Renewal/RefreshQueueStoreTests.swift`

- [ ] **Step 1: 写恢复语义测试**

```swift
@Test
func restartPreservesCompletedItemsAndMarksSubmittedInstallUnknown() async throws {
    let fileURL = temporaryFileURL()
    let store = BatchRenewalTransactionStore(fileURL: fileURL)
    let transaction = try await store.create(plan: .threeAppsFixture)
    try await store.markCompleted(transaction.items[0].id)
    try await store.markInstallSubmitted(transaction.items[1].id, submissionID: UUID())

    let restarted = BatchRenewalTransactionStore(fileURL: fileURL)
    let recovered = try #require(await restarted.recover())
    #expect(recovered.items[0].state == .completed)
    #expect(recovered.items[1].state == .resultUnknown)
    #expect(recovered.items[2].state == .pending)
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/RefreshQueueStoreTests`

Expected: FAIL，新事务Store不存在。

- [ ] **Step 3: 实现版本化事务**

```swift
struct BatchRenewalTransaction: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case running, paused, awaitingSealConfirmation, completed }
    struct Item: Codable, Equatable, Identifiable, Sendable {
        enum State: String, Codable, Sendable {
            case pending, preparing, signing, installSubmitted, resultUnknown
            case completed, failed, accountPaused, skipped
        }
        let id: UUID
        let appID: UUID
        let accountID: UUID
        let name: String
        let isSeal: Bool
        var state: State
        var submissionID: UUID?
        var failureCode: String?
    }
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var state: State
    var items: [Item]
    var cursor: Int
    var pauseCode: String?
    var selfReplacementTransactionID: UUID?
}
```

Store所有状态变更原子写盘；有未结算 transaction时 `create` 返回 `activeTransactionExists`。保留旧 RefreshQueue JSON解码迁移：running变 resultUnknown、completed保持、pending保持，然后以新格式覆盖。

- [ ] **Step 4: 运行Store测试并提交**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/RefreshQueueStoreTests`

Expected: PASS。

```bash
git add Seal/Core/Renewal/BatchRenewalTransaction.swift Seal/Infrastructure/Renewal/RefreshQueueStore.swift SealTests/Renewal/RefreshQueueStoreTests.swift
git commit -m "feat: persist batch renewal transactions"
```

### Task 4：按App、账号、全局三个作用域分类失败

**Files:**

- Create: `Seal/Core/Renewal/BatchRenewalFailurePolicy.swift`
- Create: `SealTests/Renewal/BatchRenewalFailurePolicyTests.swift`

- [ ] **Step 1: 写错误代码矩阵测试**

```swift
@Test(arguments: [
    FailureCase("SEAL-IPA-001", .app),
    FailureCase("SEAL-SIGN-401", .app),
    FailureCase("SEAL-AUTH-1100", .account),
    FailureCase("SEAL-CERT-204", .account),
    FailureCase("SEAL-PAIR-205", .global),
    FailureCase("SEAL-INSTALL-706", .global),
    FailureCase("SEAL-DATA-001", .global)
])
func classifiesFailureScope(testCase: FailureCase) {
    #expect(BatchRenewalFailurePolicy.scope(forCode: testCase.code) == testCase.scope)
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/BatchRenewalFailurePolicyTests`

Expected: FAIL，策略不存在。

- [ ] **Step 3: 实现类型优先、代码兜底的策略**

```swift
enum BatchFailureScope: Equatable, Sendable { case app, account, global }

enum BatchRenewalFailurePolicy {
    static func scope(for error: Error) -> BatchFailureScope {
        guard let failure = error as? ImportFailure else { return .global }
        return scope(forCode: failure.code)
    }

    static func scope(forCode code: String) -> BatchFailureScope {
        if code.hasPrefix("SEAL-PAIR-") || code.hasPrefix("SEAL-INSTALL-706")
            || code.hasPrefix("SEAL-VPN-") || code.hasPrefix("SEAL-DATA-") { return .global }
        if code.hasPrefix("SEAL-AUTH-") || code.hasPrefix("SEAL-CERT-") { return .account }
        return .app
    }
}
```

未知持久化、Keychain和事务错误按 global处理，避免在状态不可写时继续副作用。

- [ ] **Step 4: 运行测试并提交**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/BatchRenewalFailurePolicyTests`

Expected: PASS。

```bash
git add Seal/Core/Renewal/BatchRenewalFailurePolicy.swift SealTests/Renewal/BatchRenewalFailurePolicyTests.swift
git commit -m "feat: classify batch renewal failures"
```

### Task 5：顺序执行普通App并按账号隔离失败

**Files:**

- Create: `Seal/Core/Renewal/BatchRenewalRunner.swift`
- Modify: `Seal/Core/Renewal/RenewalCoordinator.swift`
- Create: `Seal/Core/Signing/InstallSubmissionRecorder.swift`
- Modify: `Seal/Core/Signing/SigningCoordinator.swift`
- Create: `SealTests/Renewal/BatchRenewalRunnerTests.swift`
- Modify: `SealTests/Signing/SigningCoordinatorSignedArtifactTests.swift`

- [ ] **Step 1: 写A失败B继续、账号失败跳组、全局失败暂停测试**

```swift
@Test
func appFailureContinuesButGlobalFailurePauses() async throws {
    let signer = ScriptedRenewalExecutor(results: [.appFailure, .success, .globalFailure])
    let fixture = try await BatchRunnerFixture.make(executor: signer)
    let result = try await fixture.runner.run()
    #expect(result.items[0].state == .failed)
    #expect(result.items[1].state == .completed)
    #expect(result.state == .paused)
}

@Test
func accountFailureSkipsOnlyRemainingItemsForThatAccount() async throws {
    let fixture = try await BatchRunnerFixture.twoAccounts(firstAccountFails: true)
    let result = try await fixture.runner.run()
    #expect(result.itemsForFirstAccount.contains(where: { $0.state == .accountPaused }))
    #expect(result.itemsForSecondAccount.allSatisfy { $0.state == .completed })
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/BatchRenewalRunnerTests`

Expected: FAIL，Runner不存在。

- [ ] **Step 3: 实现严格顺序Runner**

```swift
protocol AppRenewalExecuting: Actor {
    func renew(appID: UUID, accountID: UUID) async throws -> RenewalExecutionResult
}

actor BatchRenewalRunner {
    func run() async throws -> BatchRenewalTransaction {
        var transaction = try await store.requireActive()
        while let item = transaction.nextPendingOrdinaryItem {
            try await store.markPreparing(item.id)
            do {
                let result = try await executor.renew(appID: item.appID, accountID: item.accountID)
                try await store.markCompleted(item.id, result: result)
            } catch {
                switch failurePolicy.scope(for: error) {
                case .app: try await store.markFailed(item.id, error: error)
                case .account: try await store.pauseAccount(item.accountID, error: error)
                case .global:
                    try await store.pauseAll(error: error)
                    return try await store.requireActive()
                }
            }
            transaction = try await store.requireActive()
        }
        return try await submitSealLastIfEligible()
    }
}
```

Runner不并发安装。新增注入 `SigningCoordinator` 的提交记录边界：

```swift
protocol InstallSubmissionRecording: Sendable {
    func willSubmitInstall(appID: UUID) async throws -> UUID
}
```

`SigningCoordinator` 必须在调用 `InstallChannel.install` 的紧前一行先调用 recorder；批量 recorder 原子写入 `installSubmitted`/submissionID，无活动批次时使用 no-op recorder。记录失败则不得提交安装。进程恢复或安装超时把该项变为 `resultUnknown` 并暂停对账，不自动重传。测试用 recording channel 断言事件顺序严格为 `persisted`、`submitted`，并覆盖落盘失败时 channel调用次数为0。

- [ ] **Step 4: RenewalCoordinator改成Facade**

保留现有单 App API；批量入口只负责创建计划/事务并调用 Runner。删除 AppsViewModel中的业务循环，ViewModel只接收事务快照。

- [ ] **Step 5: 运行测试并提交**

Run:

```bash
bash Scripts/ci-test.sh \
  -only-testing:SealTests/BatchRenewalRunnerTests \
  -only-testing:SealTests/RefreshPlannerTests \
  -only-testing:SealTests/SigningCoordinatorSignedArtifactTests
```

Expected: PASS。

```bash
git add Seal/Core/Renewal/BatchRenewalRunner.swift Seal/Core/Renewal/RenewalCoordinator.swift Seal/Core/Signing/InstallSubmissionRecorder.swift Seal/Core/Signing/SigningCoordinator.swift SealTests/Renewal/BatchRenewalRunnerTests.swift SealTests/Signing/SigningCoordinatorSignedArtifactTests.swift
git commit -m "feat: run account-isolated batch renewal"
```

### Task 6：Seal最后提交并由新进程合并批次结果

**Files:**

- Modify: `Seal/Core/Renewal/BatchRenewalRunner.swift`
- Modify: `Seal/Core/Renewal/SelfReplacementCoordinator.swift`
- Modify: `Seal/Core/Renewal/SelfAppRegistrar.swift`
- Create: `SealTests/Renewal/BatchSealLastTests.swift`

- [ ] **Step 1: 写Seal顺序与跨进程恢复测试**

```swift
@Test
func SealIsSubmittedOnlyAfterEveryOrdinaryItemHasTerminalState() async throws {
    let fixture = try await BatchRunnerFixture.withSealAndTwoApps()
    _ = try await fixture.runner.run()
    #expect(await fixture.executor.callOrder == [fixture.appAID, fixture.appBID, fixture.sealID])
    #expect(try await fixture.store.requireActive().state == .awaitingSealConfirmation)
}

@Test
func newSealProcessCompletesOriginalBatch() async throws {
    let fixture = try await BatchRunnerFixture.awaitingConfirmedSeal()
    try await fixture.registrar.ensureRegistered()
    let batch = try #require(await fixture.store.loadLatest())
    #expect(batch.state == .completed)
    #expect(batch.items.last?.state == .completed)
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/BatchSealLastTests`

Expected: FAIL，批次未关联 self replacement transaction。

- [ ] **Step 3: 关联事务而不复制自替换状态**

Runner提交 Seal前先写：

```swift
try await batchStore.markAwaitingSeal(
    batchID: batch.id,
    itemID: sealItem.id,
    selfReplacementTransactionID: replacement.id
)
try await selfReplacement.submitPrepared(transactionID: replacement.id, progress: progress)
```

新进程 SelfAppRegistrar完成自替换 settle后调用 `batchStore.resolveSealReplacement(id:result:)`。普通 App结果不受 Seal失败影响；Seal需要电脑恢复时批次结论为 partial/recoveryRequired。

- [ ] **Step 4: 运行测试并提交**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/BatchSealLastTests`

Expected: PASS。

```bash
git add Seal/Core/Renewal/BatchRenewalRunner.swift Seal/Core/Renewal/SelfReplacementCoordinator.swift Seal/Core/Renewal/SelfAppRegistrar.swift SealTests/Renewal/BatchSealLastTests.swift
git commit -m "feat: renew Seal last in batch"
```

### Task 7：外部覆盖后的显式重新接管

**Files:**

- Modify: `Seal/Features/Apps/AppsViewModel.swift`
- Modify: `Seal/Features/Apps/InstalledAppActionSheet.swift`
- Modify: `Seal/Core/Import/ImportWorkflow.swift`
- Create: `SealTests/Apps/ExternalOverrideTakeoverTests.swift`

- [ ] **Step 1: 写无用户确认不得覆盖测试**

```swift
@Test
func externallyChangedAppIsExcludedUntilExplicitTakeover() async throws {
    let fixture = try await ExternalOverrideFixture.make()
    #expect(fixture.app.managementState == .installedExternallyChanged)
    await #expect(throws: ManagedAppFailure.takeoverConfirmationRequired) {
        try await fixture.viewModel.renew(fixture.app)
    }
    let authorizationID = try await fixture.viewModel.confirmTakeover(appID: fixture.app.id)
    let authorized = try #require(await fixture.store.fetch(id: fixture.app.id))
    #expect(authorized.managementState == .installedExternallyChanged)
    #expect(authorized.externalTakeoverAuthorizationID == authorizationID)

    try await fixture.viewModel.renew(authorized)
    let installed = try #require(await fixture.store.fetch(id: fixture.app.id))
    #expect(installed.managementState == .installedManaged(source: .available))
    #expect(installed.externalTakeoverAuthorizationID == nil)
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/ExternalOverrideTakeoverTests`

Expected: FAIL，当前没有外部覆盖状态闸门。

- [ ] **Step 3: 添加确认入口**

外部覆盖 App操作页展示变化证据、“保留外部版本”和“由 Seal重新接管”。确认只授权下一次签名覆盖；只有安装成功后才恢复 `installedManaged`。重新导入同 Bundle IPA更新原始来源，但仍需确认覆盖。

- [ ] **Step 4: 运行测试并提交**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/ExternalOverrideTakeoverTests`

Expected: PASS。

```bash
git add Seal/Features/Apps/AppsViewModel.swift Seal/Features/Apps/InstalledAppActionSheet.swift Seal/Core/Import/ImportWorkflow.swift SealTests/Apps/ExternalOverrideTakeoverTests.swift
git commit -m "feat: require confirmation after external app override"
```

### Task 8：一键续签界面、继续与结果汇总

**Files:**

- Modify: `Seal/Features/Apps/BatchRefreshView.swift`
- Modify: `Seal/Features/Apps/AppsViewModel.swift:1360-1610`
- Modify: `Seal/Features/Apps/AppsRootView.swift`
- Create: `SealTests/Renewal/BatchRenewalPresentationTests.swift`
- Create: `SealUITests/BatchRenewalUITests.swift`

- [ ] **Step 1: 写汇总模型测试**

```swift
@Test
func partialResultSeparatesSuccessActionAndNotRun() {
    let presentation = BatchRenewalPresentation(.partialFixture)
    #expect(presentation.headline == "部分完成")
    #expect(presentation.success.count == 1)
    #expect(presentation.needsAction.count == 1)
    #expect(presentation.notRun.count == 1)
    #expect(presentation.primaryAction == .continueUnfinished)
}
```

- [ ] **Step 2: 运行并确认失败**

Run: `bash Scripts/ci-test.sh -only-testing:SealTests/BatchRenewalPresentationTests`

Expected: FAIL，展示模型不存在。

- [ ] **Step 3: ViewModel只驱动事务**

`beginBatchRefresh` 创建全量计划；存在 active transaction时显示“继续未完成项目”或“结束旧批次”，不覆盖文件。`BatchRefreshView`按成功、需要处理、未执行分区，显示账号、阶段和恢复动作。

等待 Seal确认时固定文案“已提交 Seal安装，重新打开 Seal后确认”，不显示再次安装按钮。

- [ ] **Step 4: 添加UI测试**

测试所有 App均出现、A失败B继续、账号组暂停、全局暂停后继续、Seal最后以及新进程结果恢复。

- [ ] **Step 5: 全量验证并提交**

Run:

```bash
xcodegen generate
bash Scripts/ci-test.sh
python3 Scripts/verify-release-safety.py
```

Expected: 全部退出0。

```bash
git add Seal/Features/Apps/BatchRefreshView.swift Seal/Features/Apps/AppsViewModel.swift Seal/Features/Apps/AppsRootView.swift SealTests/Renewal/BatchRenewalPresentationTests.swift SealUITests/BatchRenewalUITests.swift
git commit -m "feat: finish one-tap renewal experience"
```
