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

### 2.5 自替换的安装调用**从未返回**，而这段一行日志都没有（问题 1 已由真机日志坐实）

上一轮的三个修复（批量收不到 `.installing`、安装期无反馈、`.inactive` 早退）落地后用户复测仍卡在 93%。这一轮直接从用户导出的日志里找到了确凿证据 —— 关键不是「卡住了」，而是**同一份日志里有一个 7 秒完成的对照**。

`Seal-log(7).txt`（同一天、同一台设备、同一次会话）：

| 时间 | 事件 | 说明 |
| --- | --- | --- |
| `16:53:57` | `安装 签名产物核验通过：证书 …F81192E2 …` | **Seal 自替换**的安装起点 |
| `16:55:30` | `续签 [SEAL-BATCH-DEBUG-4] restore skipped…` | **93 秒空白**后出现的第一条日志，且与安装无关 |
| `16:59:06` | `安装 签名产物核验通过：证书 …2DAE6F58 …` | 普通 App（LiveContainer，4 个 target）的安装起点 |
| `16:59:13` | `签名 签名并安装成功` | **7 秒**完成 |

补充证据：

- `16:55`–`17:02` 进程一直活着、照常打后台日志（`BatchDebug restore skipped`、`LocalDevVPN 正常`、`Apple 侧证书状态已同步`）⇒ **Seal 从未被替换**（否则进程会被新包终止），也没有任何安装结论；
- `Seal-log(8).txt`：`19:43:50` 与 `19:45:51` 各有一次 Seal 自替换安装起点，间隔 **91 秒**，两次都没有结论 —— 第二次是用户在「怎么都没反应」之后**重试**。

根因（代码侧）：

```swift
// 旧实现：MinimuxerInstallChannel.install(ipaData:bundleID:isSelfReplacement:onProgress:)
if isSelfReplacement {
    let installation = Task.detached(priority: .userInitiated) {
        try Minimuxer.stageAndInstall(bundleId: bundleID, ipaBytes: ipaData, progress: syncProgress)
    }
    try await installation.value          // ← 没有超时、没有任何日志
} else {
    let outcome = await offThread(seconds: mergedTimeout) { ... }   // 普通 App 有超时兜底
}
```

`Minimuxer.stageAndInstall` 是**同步阻塞 FFI，没有取消机制**。它不返回 ⇒ 界面永久停在 93%、日志永久静默、用户无从判断「在装」还是「死了」。普通 App 分支有 `offThread(seconds: mergedTimeout)` 兜底，**这就是为什么只有 Seal 自续签会永久卡住**。

同时，91 秒内两笔提交说明还存在第二个风险：**同一个 Bundle ID 上叠了两个 installd 安装命令**（R05 要防的「第二次安装」）。

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

### 3.6 触发点从界面搬到状态层（本轮补修）

「回主页」的动作原先挂在 `SigningProgressView` 的 `.onChange(of: viewModel.signingSession?.status)` 上。这在**加了「取消」按钮之后**变成了一个真实缺陷：

- 「取消」是软取消 —— 立即关界面、`signingSession = nil`，但**已经下发的安装由 installd 跑完**；
- 用户在 Seal 自续签的安装阶段点「取消」⇒ `SigningProgressView` 消失 ⇒ 挂在它上面的触发点收不到后续阶段推进 ⇒ **「回主页」永远不会发生**；
- iOS 只有在旧进程让出前台后才完成替换 ⇒ Seal 的替换**静默失败**：旧版本继续跑，用户以为更新没生效。

修复：触发点搬到状态层 `AppsViewModel.updateSigningStage`，与批量续签那条链路（`consumeBatchEvent`）对齐；界面上的 `.onChange` **只保留视觉转场**（`withAnimation` 渲染「正在退回主屏幕」）。

```swift
// AppsViewModel.updateSigningStage
let tick = InstallStageTimeline.tick(entering: stage, currentStage: currentStage)
...
signingSession?.status = .running(stage)
// `.restart` = 只在**首次**进入安装阶段触发一次（同一阶段会被重复推送：
// 安装通道的 >1.0 哨兵 + 签名侧补发），不设闸门会排出多个「回主页」任务。
if stage == .installing,
   tick == .restart,
   signingSession?.app.isSeal == true {
    SelfInstallAutoBackground.returnToHomeAfterSealUpload()
}
```

守卫同时断言**界面里不得再出现** `SelfInstallAutoBackground.returnToHomeAfterSealUpload()` —— 两处都触发会排出两个系统转场和两个 `exit(0)` 兜底。

### 3.7 自替换安装：看门狗（只停止等待、绝不取消）+ 日志 + 单飞闸门（本轮新增，见 §2.5）

三件事，都针对「自替换的安装调用不返回」：

**(1) 看门狗 —— 有界失败，且绝不取消底层 FFI**

```swift
// MinimuxerInstallChannel.waitForSelfReplacement
_ = try await HardTimeout.run(seconds: budget, cancelsWorkOnTimeout: false) {
    try await installation.value
    return true
}
```

`cancelsWorkOnTimeout: false` 是**要害**，不能复用 `offThread`：它走 `HardTimeout.run` 的默认 `true`，超时会把承载 `stageAndInstall` 的任务 `cancel()`。同步 FFI 响应不了取消，但 Rust 侧若把取消信号当「调用方放弃」来清理，就会**撤销已经下发的 installation_proxy 命令** —— 把「可能还在装」变成「确定装不上」。

超时后**不重试**（R05：底下那次很可能还在跑），并把 `installTimeoutFailure` **原样抛出**，不再经 `installationFailure` 归类改写文案（否则用户看到的是泛泛的「安装失败」而不是「安装超时」）。

**(2) 日志出口 —— 这段原先一行日志都没有**

`MinimuxerInstallChannel` 注入可选 `SealLogStore`（`AppContainer` 把 logStore 的构造提前到安装通道之前），每次安装写「开始 / 已返回 / 抛错 / 等待超时」；自替换等待期间每 15 秒一条心跳（安装阶段 installd 不回报任何进度，心跳是唯一的活性信号）。**每条日志立刻 `flush()`**：自替换的终点是当前进程被替换掉，留在缓冲里的最后几行会随进程一起消失，而用户导出的 `Documents/Seal-log.txt` 正是 `flush()` 镜像的。

**(3) 单飞闸门 —— 挡住并发的第二笔**

```swift
struct SelfReplacementInstallGate {
    private(set) var isInFlight = false
    mutating func acquire() -> Bool { ... }          // 已有安装在进行 → 拒绝
    mutating func release(timedOut: Bool) { ... }    // 超时**不解锁**（底下那次很可能还在跑）
}
```

两条重试路径（`install(...)` 与 `installPushedIpa`）都把「被闸门拒绝」按终态处理并原样抛出：重试只会被同一个闸门再拒一次，而重试路径里的 `Minimuxer.reset()` / `Install.resetProvider()` 还会把**可能仍在跑的安装连接**拆掉 —— 比不重试更糟。

**(4) 顺带消掉一份重复实现**

无进度的 `install(ipaData:bundleID:isSelfReplacement:)` 改为转发到带进度的实现（`onProgress: { _ in }`），不再各自维护一份「自替换必须带看门狗 / 必须记日志 / 必须单飞」的规则 —— 两份拷贝漂移时不会有任何编译或测试信号。

### 3.8 模拟器切片缺符号：把「记得小心」换成守卫（本轮补修，CI 反馈驱动）

§3.7 的改动推送后 CI run `35168295836`：`rork-sign-tests` ✓、`build-package` ✓、**`swift-regression` ✗** ——

```
MinimuxerInstallChannel.swift:480:56: error: type 'Self' has no member 'isTimeoutInstallError'
```

**根因**：`waitForSelfReplacement` / `runSelfReplacementInstall` 刻意放在 `#if !targetEnvironment(simulator)` **之外**（模拟器上也要能编译），但它们调用的 `isTimeoutInstallError` 仍定义在 `#if` **之内**。设备切片看得到、模拟器切片看不到。

**为什么不能只靠「下次注意」**：`build-package` 只编设备切片，这类错误在它那里**永远绿**；只有 `swift-regression`（模拟器切片）会红，而一轮 CI 13–16 分钟。**同一轮里这是第二次**（`diagnostic` 已经因同样原因提前挪出，`isTimeoutInstallError` 漏了），所以本轮把它做成守卫的**通用**检查。

**修复**：把 `diagnostic(_:)`、`isTimeoutInstallError(_:)`、`isSelfReplacementBusyError(_:)` 全部移到 `#if` 之外（这三段逻辑与平台无关），`#if` 内留指路注释避免重复定义。

**守卫实现**（`Scripts/verify-release-safety.py`）：

1. `simulator_activity(condition)`：只认识 `targetEnvironment(simulator)` 这一种条件，返回它在模拟器切片下的真假；不认识的写法（`#if DEBUG` / `#if os(iOS)`）返回 `None`，按「两片都编译」处理 —— 取值不取决于目标平台，既不漏真问题也不制造误报。
2. `mask_inactive_on_simulator(text)`：把「模拟器切片不编译」的行整段抹成等长空白（保留换行，行号不变）。
3. 检查：找出**只**出现在被抹掉部分里的顶层类型成员（`_SIMULATOR_MEMBER`，**只认缩进恰好 4 空格**的声明），却出现在抹后文本中 ⇒ 模拟器代码引用了设备专属符号。

两个必须避开的坑（都实际踩过并修掉）：

- **判定要同时覆盖两种写法**：`#if !targetEnvironment(simulator)` 的整个分支 **和** `#if targetEnvironment(simulator)` 的 **`#else` 分支** —— 两段都不在模拟器上编译。第一版只认前者，于是 `bindTunnelConfiguration()`（定义在 `!simulator` 里、调用点在同文件的 `#else` 里）被误报成缺符号。**误报比漏报更坏：它会逼着后来的人把守卫删掉。**
- **只认缩进恰好 4 空格的声明**。函数体内的局部变量缩进更深，`let ipaMB` / `let detail` 这类名字在设备专属分支与模拟器分支里各有一份，按「名字出现在抹后文本里」判定会把它们全部误报。

性能：循环里先用**未去注释的原文**做一次廉价子串判断再决定是否 `strip_comments`（这个循环要跑遍 200+ 文件，而 `violations()` 总共要跑 90 多遍）。

配套变异锚点：把 `isTimeoutInstallError` 的定义包回 `#if !targetEnvironment(simulator)`，守卫必须报红 —— 这条同时证明检查不是空转。

---

## 4. 守卫与测试

`Scripts/verify-release-safety.py`：

- 新增 **R10**（安装阶段「看得见、退得出」）：19 条断言 + 13 个变异锚点，覆盖
  - 哨兵必须排他（`>` 而非 `>=`）；
  - **两个**安装分支都要走 `bridgedInstallProgress`，且包装里真的发 `.installing`；
  - 批量事件流必须带真实百分比（`onInstallProgress` 订阅 + `.appInstallProgress` 事件）；
  - 两个界面必须有 `InstallWaitNote` 与取消按钮；
  - 运行中不得隐藏 footer；
  - `step(for:)` 必须是**可测纯函数**，`.inactive → .waitForForeground`、`.background → .standDown`、`@unknown default` 不放弃，且等待循环**真的走** `step()` 并真的 `sleep`（结构还在 ≠ 还在用）；
  - **「回主页」的触发点在状态层**（`AppsViewModel`，且用 `.restart` 闸门只触发一次），界面里**不得**再出现调用（两处都触发 = 两个转场 + 两个 `exit(0)` 兜底）；
  - 安装计时起点规则只有一份：`AppsViewModel` 与 `BatchRefreshSession` 都必须调 `InstallStageTimeline.tick`；
  - **自替换的等待必须带超时且 `cancelsWorkOnTimeout: false`**（超时只停止等待、绝不取消 FFI）；
  - `installation.value` **只允许在一处**被 await、`Task.detached(priority: .userInitiated)` **只允许出现一次** —— 在别处再裸等一遍等于重新引入无超时等待；
  - 自替换必须走**单飞闸门**，且超时**不得**解锁（`release(timedOut: Self.isTimeoutInstallError(error))`）；
  - 安装链路必须**真的接上**日志出口（`AppContainer` 的 `installChannel` 构造段里必须有 `logStore: logStore`；用 `section()` 限定范围 —— 该文件里 `logStore: logStore` 在签名协调器构造处也出现一次，全局匹配会让变异检不出来）；
  - 自替换安装必须写「开始 / 已返回」日志，等待期间必须有心跳；
  - 两个新单测文件里的**关键断言确实存在** —— 源码断言守「形状」，单测守「行为」，测试被删空不能仍然全绿。
- **新增通用检查 `Simulator: device-only members must not be referenced by simulator code`**（见 §3.8）：把「模拟器切片不编译」的行整段抹成等长空白，再找出**只**在被抹掉部分里定义的顶层类型成员、却出现在抹后文本中的那些。
- **R09 通用化**：把「实参标签顺序必须与声明一致」做成可复用校验，覆盖 `AppRecord` / `signAndInstall` / `installSignedIPA` / `installCachedSignedIPAIfPossible`，并**断言扫到的调用点数下限** —— 本轮第一版正则把真实调用点（`coordinator.signAndInstall(`，前一个字符是 `.`）全部排除，变成「零调用点 ⇒ 零错误 ⇒ 绿」。
- 新增 `squash()`：把多行代码压成一行式断言，不再在守卫里拼换行符 + 数缩进空格（缩进一改守卫就会莫名其妙地红）。
- 修掉守卫自身的性能问题：每遍（= 每个变异）内缓存 `load` / `strip_comments`，`rglob` 结果进程内只算一次。**2 分 47 秒 → 48 秒**（此前已慢到被默认命令超时 SIGTERM，表现为「无输出、exit 1」）。

新增测试：

- `SealTests/Signing/InstallStageBridgeTests.swift`（2 条）：哨兵排他性、`enabled == false` 时不补发。
- `SealTests/Renewal/BatchRefreshSessionTelemetryTests.swift`（5 条）：只在 `.pushing` 采信百分比、越界钳制、安装起点只记一次、离开安装阶段清空遥测。
- `SealTests/DesignSystem/InstallWaitNoteTests.swift`（2 条）：`m:ss` 格式化与负数钳制。
- `SealTests/Apps/SelfInstallAutoBackgroundTests.swift`（5 条）：`.inactive` 必须 `.waitForForeground`（问题 1 的根因回归）、只有 `.background` 允许 `.standDown`、未知状态按「还在前台」处理、穷举「全部已知状态里恰好一个走 `.standDown`」。
- `SealTests/Signing/InstallStageTimelineTests.swift`（5 条）：首次进入安装阶段记起点、重复推送不重置、其它阶段一律清空、`.keep` 不会凭空补一个起点、批量链路与共享规则一致。
- `SealTests/Installation/SelfReplacementInstallGateTests.swift`（4 条）：已有安装在进行时第二笔必须被拒、安装结束后解锁、**超时不解锁**、连续超时永不重开。
- `SealTests/Concurrency/HardTimeoutTests.swift` 补 1 条：`cancelsWorkOnTimeout: false` 时**工作所在任务**的 `Task.isCancelled` 仍为 `false`（断言必须打在 `HardTimeout` 自己创建的那个任务上 —— 在闭包里再套一层 `Task.detached` 就会测到新任务，测试会退化成永远通过）。

结果：**204 源码断言 + 90 变异 PASS**，耗时约 61 秒。（旧断言 `count("if Self.isTimeoutInstallError(error) {") == 2` 因两个 `install` 重载合并成一份而降为 `1`，已同步改为「唯一的重试循环必须把超时当终态」。）

---

## 5. 待真机验证

1. 批量续签：抽屉显示上传百分比；上传完成立即从「传输中」变「安装中」并出现「已等待 m:ss」。
2. 单签续签：进入安装阶段（93%）后出现等待说明而不是一片空白。
3. 运行中点「取消」/「取消续签」：界面立即关闭，日志出现 `SEAL-SIGN-012` / `SEAL-RENEW-011`，列表刷新后能看到真实结果。
4. Seal 自续签：在下拉控制中心（`.inactive`）之后仍能完成替换，不再停在 93%。
5. 批量续签普通 App：确认不再出现长时间停在「传输中」的项。
6. Seal 自续签：进入安装阶段后点「取消」关掉抽屉，Seal **仍能完成替换**（触发点已在状态层，不随界面消失）—— 这条正是上一轮补修的缺陷（§3.6）。
7. Seal 自续签：导出日志应能看到**安装链路的完整轨迹** —— `安装 开始自替换安装：…` → 等待期间每 15 秒一条 `自替换安装仍在等待：已等待 N 秒` → 最后是 `自替换安装调用已返回：…`（成功）或 `自替换安装等待超时：…`（有界失败）。**这条是下一轮排查的入口**：无论成功还是失败，日志都能指出卡在哪一段（上传 / installd / 回主页转场）。
8. Seal 自续签：如果出现 `自替换安装仍在等待` 但永远不返回，请把日志发回来 —— §6 里「为什么自替换的安装调用不返回」目前只有调用侧证据，需要设备侧轨迹才能定位。

---

## 6. 未解决 / 待决策

| 项 | 现状 | 需要的动作 |
| --- | --- | --- |
| 安装/上传超时预算偏长 | `mergedTimeout = min(1800, 180 + ipaMB×5) + 600`，20MB 包 ≈ 878 秒 | 是否缩短需用户拍板。缩短的代价是慢设备上的假超时：超时按**确定性拒绝**处理且不重试，但底层安装可能仍在跑 ⇒ 「装上了却记为失败」 |
| 批量链路的「回主页」没有 `.restart` 闸门 | `consumeBatchEvent` 里 `if stage == .installing` 未按首次进入过滤，`.installing` 被重复推送时会排出多个「回主页」任务 | 已知且**良性**（第一个任务触发转场后进程被挂起，后续任务不会执行；转场失败时第一个 `exit(0)` 已结束进程），故本轮未动。若要统一，让 `BatchRefreshSession.advanceStage` 返回 `Tick` 即可 |
| 问题 1 的**调用侧**证据 | 已坐实：真机日志里普通 App 安装 7 秒完成（`16:59:06→16:59:13`），而 Seal 自替换在 `16:53:57` 之后 93 秒无任何安装结论、进程仍活着且从未被替换 ⇒ 自替换的 `stageAndInstall` **没有返回**（§2.5） | 已通过看门狗把「永久卡住」变成「有界失败 + 可查日志」。剩下的只是下一轮真机日志复核 |
| 自替换的安装调用**为什么不返回** | 仍未知。首要嫌疑是 `SelfInstallAutoBackground` 的 `suspend`：它在上传完成（进入 `.installing`）后 1.2 秒就触发，而 `MinimuxerInstallChannel` 的注释明确写着「主动调用 `UIApplication.suspend` 会**冻结当前进程内的 installation_proxy 连接**，安装永远到不了完成回调」—— **这两处语义直接冲突**。次要嫌疑是无线链路下 AFC 暂存 / installd 解压卡住 | **下一轮日志即可判定**（看门狗的心跳就是探针）：日志停在 `开始自替换安装：…` 而**没有**任何 `自替换安装仍在等待` ⇒ 进程被挂起（`suspend` 命中，转场时机错了）；**有**心跳 ⇒ 进程活着，卡在 AFC/installd。若坐实前者，把转场触发点从「进入 `.installing`」推迟到「安装调用返回之后」，或改为只 `exit(0)` 不 `suspend`，需真机 A/B |
| 问题 6 | 用户消息被截断（「6、签名、续签」） | 待用户补完 |
