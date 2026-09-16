# 续签「卡在 93%」与「卡在传输」——安装阶段的反馈缺失 + 自替换的永久冻结

日期：2026-09-16
关联用户反馈：问题 1「续签到安装步骤，卡在 93% 的为止没反应了，怎么都没反应」；问题 2「续签抽屉卡在传输那没反应，一直没反应」
上一份报告：`docs/qa/2026-09-16-profile-pileup-and-ui-row-layout.md`（问题 3/4/5）

---

## 1. 现象与判据

两个反馈指向同一段代码区间，但**不是同一个 bug**。先把「看到什么」映射到「代码里是哪个状态」：

| 用户看到 | 对应状态 | 判据位置 |
| --- | --- | --- |
| 单签进度环停在 **93%** | `SigningStage.installing` | `SigningProgressView.overallProgress`：`case .installing: return 0.93` |
| 批量抽屉某项显示 **「传输中」** | `SigningStage.pushing` | `BatchRefreshView.runningStageTitle`：`case .pushing: return "传输中"` |
| 批量抽屉某项显示 **「安装中」** | `.installing` 或 `.verifying` | 同上 |
| 批量抽屉 Seal 那项显示 **「即将更新」** | `.preparingSealUpdate` | `BatchRefreshView.title(for:isSeal:stage:)` |

推论（重要）：**「卡在传输中」的那一项不可能是 Seal** —— Seal 在批量里一旦进入 `.pushing` 就会被渲染成「即将更新 Seal」（`AppsViewModel.consumeBatchEvent` 里 `app.isSeal && (stage == .pushing || stage == .installing)` ⇒ `status = .preparingSealUpdate`）。所以问题 2 卡住的是**普通 App**。

---

## 2. 根因

### 2.1 批量续签的普通 App 收不到「安装中」（问题 2 的直接根因）

`SigningCoordinator.installSignedIPA` 的普通 App 分支只发一次 `.pushing`：

```swift
try await updateState(appID: app.id, stage: .pushing)
await progress(.pushing)
try await installChannel.install(...)
```

安装通道的上传进度是 **Double**（0→1.0 逐值），上传结束、installd 即将安装时再发一个 **>1.0 的哨兵**（Rust 侧 101 → 1.01）。

- 单签路径：`AppsViewModel.updateInstallProgress` 直接订阅这个 Double，`> 1.0` 时把阶段切到 `.installing` ⇒ 用户看到 93%。
- 批量路径：`BatchRefreshEvent.appProgress` **只承载 `SigningStage`**，接不到 Double。原标志 `broadcastInstallingForSelfReplacement` 只在 **Seal 分支**补发 `.installing`（用途是驱动自动回主页），普通 App 什么都没有。

⇒ 普通 App 从**上传完成**到 **installd 装完**（可达数分钟）整段停在「传输中」，中间没有任何状态变化。这就是「卡在传输那没反应」。

### 2.2 安装阶段本身没有任何可见反馈（两个问题共同的体验缺口）

installd 通过 installation_proxy 安装时**不回报进度**。所以：

- 单签只能给出一个静止的 93%（Seal 自替换显示「替换中」转圈，普通 App 连转圈都没有）；
- 批量连百分比都没有，「传输中」是一个没有分母的黑盒。

旧代码里这段时间是纯粹的空白：没有说明、没有计时、也没有假进度。

### 2.3 Seal 自续签的「回主页」可能永久不触发（问题 1 最可能的根因）

```swift
// 旧实现
try? await Task.sleep(nanoseconds: transitionBeatNanoseconds)
let app = UIApplication.shared
guard app.applicationState == .active else { return }   // ← 这里
triggerHomeTransition(app)
try? await Task.sleep(nanoseconds: exitFallbackNanoseconds)
exit(0)
```

`UIApplication.State.inactive` 是**瞬时**失焦：控制中心、通知横幅、来电、App 切换器预览、系统弹窗、权限弹窗。此时**进程仍在前台**。

- Seal 自续签 = 覆盖安装正在运行的自己，而 **iOS 只有在旧进程让出前台后才完成替换**（代码注释与设计文档都写明了这一点）；
- `.inactive` 命中那个 `guard` 就 `return`，**连 `exit(0)` 兜底一起跳过**；
- 进程继续留在前台 ⇒ iOS 永远等不到替换时机 ⇒ 界面永久停在 93%，没有超时、没有报错。

`installSignedIPA` 的 Seal 分支走 `Task.detached { Minimuxer.stageAndInstall(...) }` + `try await installation.value`，**刻意没有超时**（提前退出会留下旧 profile）。所以这条路一旦卡住就是**无界等待**，唯一的出口就是上面这段「回主页」代码 —— 而它被 `guard` 静默关掉了。

### 2.4 运行中的弹窗没有任何出口（「怎么都没反应」里最难受的一半）

```swift
SealDrawer(title: title, showsFooter: !isRunning) { ... }
.interactiveDismissDisabled(isRunning)
```

运行中 footer 整段隐藏（`actions` 对 `.running` 返回 `EmptyView`），同时禁用下滑关闭。真卡住时用户被锁死在一个静止弹窗里，**没有任何操作可做**。

---

## 3. 修复

### 3.1 阶段推进：抽出可测规则，两个分支对称

`Seal/Core/Signing/InstallStageBridge.swift`（新）：

```swift
static let uploadCompletionSentinel: Double = 1.0

static func shouldEmitInstalling(uploadProgress: Double, enabled: Bool) -> Bool {
    enabled && uploadProgress > uploadCompletionSentinel
}
```

- 用 `>` 而不是 `>=`：1.0 是「上传到 100%」，设备此时还没开始安装，提前切阶段会让 UI 谎报「正在安装」。
- `enabled` = 「调用方的进度回调是否只承载 `SigningStage`」（批量续签为 `true`）。单签为 `false`，因为它的 UI 自己订阅 Double 哨兵 —— 保持「谁负责切阶段」只有一个来源。

`SigningCoordinator.bridgedInstallProgress` 让 **Seal 自替换与普通安装共用同一份包装**（此前两个分支各写一遍，其中普通分支漏了）。标志 `broadcastInstallingForSelfReplacement` 改名 `broadcastsInstallStage`（旧名字只描述 Seal 场景，掩盖了它真正的语义）。批量续签传 `true`，普通 App 由此在**上传完成时**切到 `.installing` ⇒ 抽屉显示「安装中」。

### 3.2 真实百分比进入批量抽屉

- `BatchRefreshEvent` 新增 `appInstallProgress(index:total:app:progress:)` —— 单独一个事件而不是塞进 `appProgress`：上传进度是**高频**回调，混进阶段事件会让「阶段变化」这个低频信号被淹没。
- `RenewalCoordinator` 给 `signAndInstall` 传 `onInstallProgress`，把 AFC 上传百分比转成事件。
- `BatchRefreshSession.recordInstallProgress` / `advanceStage`：只在 `.pushing` 采信百分比（其它阶段没有分母，留着就是一个永远不动的数字）；进入 `.installing` 记一次起点，离开时清掉（避免下一项复用上一项的起点算出「已等待 12 分钟」这种假象）。

「起点规则」抽成 `Seal/Core/Signing/InstallStageTimeline.swift`（新）：`tick(entering:currentStage:)` → `.keep / .clear / .restart`，`applied(_:startedAt:now:)` 落到 `Date?` 上。**单签（`AppsViewModel.updateSigningStage`）与批量（`BatchRefreshSession.advanceStage`）共用同一份** —— 这条规则原先两处各抄一遍，漂移不会编译失败、不会跑挂单测，只会让其中一条链路的计时变成假象。`updateInstallProgress` 的哨兵分支也不再自己写 `status` / `installStartedAt`，改为复用 `updateSigningStage(.installing)`。

### 3.3 安装阶段给出诚实说明 + 计时

`Seal/DesignSystem/InstallWaitNote.swift`（新）：`TimelineView(.periodic(from: .now, by: 1))` 每秒刷新，文案为「设备正在安装，此阶段没有进度回报 · 已等待 m:ss」。单签进度页与批量抽屉共用。

**刻意不编造假百分比进度条**：安装耗时与包大小、设备 IO 都相关，任何线性假设都会在慢设备上「走完却还没装完」，比不给进度更糟。

### 3.4 运行中保留退出通道

两个抽屉的 footer 改为**常显**，运行中各加一个取消按钮：

- 单签：`cancelSigning()`；批量：`cancelBatchRefresh()`。
- 语义是**软取消**并在注释里写明：立即关闭界面、停止后续项；**已经开始的那一次安装不会被中断**（`Minimuxer.stageAndInstall` 是同步阻塞 FFI，没有取消机制，强行丢弃只会留下「包传了一半」）。取消发生在签名阶段 ⇒ 队列项标回 `pending`；发生在安装阶段 ⇒ installd 自己跑完、安装校验通过后照常落库。
- 各写一条日志（`SEAL-SIGN-012` / `SEAL-RENEW-011`），不做「假装已停止」的假象。

### 3.5 自替换：只有 `.background` 才算用户离开

判断抽成纯函数，等待循环走它：

```swift
enum ReturnHomeStep: Equatable {
    case standDown           // .background：用户真的切走了
    case triggerTransition   // .active：触发与「按 Home」等价的转场
    case waitForForeground   // .inactive：瞬时失焦，进程仍占着前台
}

static func step(for state: UIApplication.State) -> ReturnHomeStep {
    switch state {
    case .active: return .triggerTransition
    case .inactive: return .waitForForeground
    case .background: return .standDown
    @unknown default: return .waitForForeground   // 宁可多等一轮，不能静默放弃
    }
}

@MainActor
private static func waitUntilExitIsSafe(_ app: UIApplication) async -> Bool {
    for _ in 0...inactiveRetryLimit {          // 最多 3 秒
        switch step(for: app.applicationState) {
        case .standDown: return false          // 交给 iOS 完成替换，不强杀进程
        case .triggerTransition: triggerHomeTransition(app); return true
        case .waitForForeground: try? await Task.sleep(nanoseconds: inactiveRetryNanoseconds)
        }
    }
    return true                                // 一直没恢复 ⇒ 走 exit(0) 兜底
}
```

- `.background` ⇒ 用户真的切走了，iOS 已能完成替换，不重复触发（避免和用户操作打架），也不强杀进程。
- `.inactive` ⇒ 等最多 3 秒等它恢复（覆盖控制中心/横幅/来电这类短暂遮挡）；恢复不了就照样走 `exit(0)` 兜底，**保证 iOS 一定能完成替换**。

**为什么抽成纯函数**：这段判断原先直接读 `UIApplication.shared.applicationState` 并就地 `return`，没有任何测试覆盖，而它的 `.inactive` 分支正是问题 1 的根因。这类「错了不崩、只会在真机上卡死」的分支必须能单测，所以把「状态 → 动作」的映射独立出来（见 §4 的 `SelfInstallAutoBackgroundTests`）。

---

## 4. 守卫与测试

`Scripts/verify-release-safety.py`：

- 新增 **R10**（安装阶段「看得见、退得出」）：16 条断言 + 11 个变异锚点，覆盖
  - 哨兵必须排他（`>` 而非 `>=`）；
  - **两个**安装分支都要走 `bridgedInstallProgress`，且包装里真的发 `.installing`；
  - 批量事件流必须带真实百分比（`onInstallProgress` 订阅 + `.appInstallProgress` 事件）；
  - 两个界面必须有 `InstallWaitNote` 与取消按钮；
  - 运行中不得隐藏 footer；
  - `step(for:)` 必须是**可测纯函数**，`.inactive → .waitForForeground`、`.background → .standDown`、`@unknown default` 不放弃，且等待循环**真的走** `step()` 并真的 `sleep`（结构还在 ≠ 还在用）；
  - 安装计时起点规则只有一份：`AppsViewModel` 与 `BatchRefreshSession` 都必须调 `InstallStageTimeline.tick`；
  - 两个新单测文件里的**关键断言确实存在** —— 源码断言守「形状」，单测守「行为」，测试被删空不能仍然全绿。
- **R09 通用化**：把「实参标签顺序必须与声明一致」做成可复用校验，覆盖 `AppRecord` / `signAndInstall` / `installSignedIPA` / `installCachedSignedIPAIfPossible`，并**断言扫到的调用点数下限** —— 本轮第一版正则把真实调用点（`coordinator.signAndInstall(`，前一个字符是 `.`）全部排除，变成「零调用点 ⇒ 零错误 ⇒ 绿」。
- 新增 `squash()`：把多行代码压成一行式断言，不再在守卫里拼换行符 + 数缩进空格（缩进一改守卫就会莫名其妙地红）。
- 修掉守卫自身的性能问题：每遍（= 每个变异）内缓存 `load` / `strip_comments`，`rglob` 结果进程内只算一次。**2 分 47 秒 → 48 秒**（此前已慢到被默认命令超时 SIGTERM，表现为「无输出、exit 1」）。

新增测试：

- `SealTests/Signing/InstallStageBridgeTests.swift`（2 条）：哨兵排他性、`enabled == false` 时不补发。
- `SealTests/Renewal/BatchRefreshSessionTelemetryTests.swift`（5 条）：只在 `.pushing` 采信百分比、越界钳制、安装起点只记一次、离开安装阶段清空遥测。
- `SealTests/DesignSystem/InstallWaitNoteTests.swift`（2 条）：`m:ss` 格式化与负数钳制。
- `SealTests/Apps/SelfInstallAutoBackgroundTests.swift`（5 条）：`.inactive` 必须 `.waitForForeground`（问题 1 的根因回归）、只有 `.background` 允许 `.standDown`、未知状态按「还在前台」处理、穷举「全部已知状态里恰好一个走 `.standDown`」。
- `SealTests/Signing/InstallStageTimelineTests.swift`（5 条）：首次进入安装阶段记起点、重复推送不重置、其它阶段一律清空、`.keep` 不会凭空补一个起点、批量链路与共享规则一致。

结果：**186 源码断言 + 80 变异 PASS**。

---

## 5. 待真机验证

1. 批量续签：抽屉显示上传百分比；上传完成立即从「传输中」变「安装中」并出现「已等待 m:ss」。
2. 单签续签：进入安装阶段（93%）后出现等待说明而不是一片空白。
3. 运行中点「取消」/「取消续签」：界面立即关闭，日志出现 `SEAL-SIGN-012` / `SEAL-RENEW-011`，列表刷新后能看到真实结果。
4. Seal 自续签：在下拉控制中心（`.inactive`）之后仍能完成替换，不再停在 93%。
5. 批量续签普通 App：确认不再出现长时间停在「传输中」的项。

---

## 6. 未解决 / 待决策

| 项 | 现状 | 需要的动作 |
| --- | --- | --- |
| 安装/上传超时预算偏长 | `mergedTimeout = min(1800, 180 + ipaMB×5) + 600`，20MB 包 ≈ 878 秒 | 是否缩短需用户拍板。缩短的代价是慢设备上的假超时：超时按**确定性拒绝**处理且不重试，但底层安装可能仍在跑 ⇒ 「装上了却记为失败」 |
| 问题 1 的真机证据 | 已从代码确认两条可能路径（`.inactive` 早退 / 安装期无反馈），但缺少卡住那一刻的日志 | 用户导出「我的 → 日志」中卡住前后 1 分钟的记录 |
| 问题 6 | 用户消息被截断（「6、签名、续签」） | 待用户补完 |
