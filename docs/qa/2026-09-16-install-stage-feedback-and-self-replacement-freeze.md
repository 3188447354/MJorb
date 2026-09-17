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

#### 2.3.1 2026-09-17 更新：真正命中的是 `.background`，不是 `.inactive`

上面那段 `guard` 把**两个**状态一起关掉了（`.inactive` 与 `.background` 都不是 `.active`）。
§3.5 的修复只把 `.inactive` 接回了「等待 ⇒ 兜底退出」，`.background` 换成了另一个写法
`return false` —— **依然是不退出**。所以 `.background` 这条路径从始至终都是坏的。

两份真机日志（`Seal-log(7).txt` / `Seal-log(8).txt`，各含两次自续签）证实命中的正是它：

| 时间（`Seal-log(7)`） | 事件 |
| --- | --- |
| `16:53:36` | `续签 Seal 自续签事务：后台保活已启动，覆盖证书、描述文件、签名和安装` |
| `16:53:57` | `安装 签名产物核验通过：…F81192E2 …`（自替换安装起点） |
| `16:55:30` 起 | 进程**继续写日志**（`[BatchDebug]`、账号同步、`安装 LocalDevVPN 正常`） |
| `16:58:20` → `16:59:13` | 批量续签 LiveContainer，**7 秒**装完 |

判据是**否证**而非推测：

- `.triggerTransition` 必然调 `suspend`。`suspend` 生效 ⇒ 进程冻结 ⇒ 日志停止。**日志没停。**
- `.waitForForeground` 超时必然 `exit(0)`。执行了 ⇒ 进程终止。**进程活着。**
- 两者都没发生 ⇒ 动作在到达它们之前就被丢掉了 ⇒ **只剩 `.standDown` 的 `return false`。**

因果链因此是：**进程不退出 ⇒ iOS 不完成替换 ⇒ installd 一直等 ⇒ `stageAndInstall` 一直不返回。**
`MinimuxerInstallChannel` 里那条「提前 suspend 会冻结当前连接」的注释描述的是这个**后果**，
与修法方向一致 —— 不是它的原因。

> 自续签还主动开了**后台保活**（第一行日志），等于把 `.standDown` 那个
> 「进程已让出前台，iOS 会自己完成替换」的前提**主动破坏掉**：保活中的进程不会自己终止。

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

> ⚠️ **2026-09-17 修正：这次只修了一半。**
>
> `.inactive` 确实修对了（等待 ⇒ 兜底退出）。但 `.background` 被写成
> `case .standDown: return false` —— 语义是「交给 iOS 完成替换，不强杀进程」。
> 而原实现里 `.background` 与 `.inactive` 一样是**不退出**的，所以这条路**依然坏着**，
> 只是换了个写法。用户在这一版复测仍卡在 93%，命中的就是它（详见 §2.3.1）。
>
> 根子在于一个**错误前提**：「进程已让出前台 ⇒ iOS 会完成替换」。
> 对覆盖安装运行中的自己，iOS 需要旧进程**终止**，而后台进程不会自己终止 ——
> 自续签还主动开了后台保活。修法见 §3.11：`.background` 也改成「有界等待 + 超时强杀」。

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

### 3.9 `#expect` 里的 mutating 调用；以及守卫的耗时波动（本轮补修，CI 反馈驱动）

§3.8 推送后 CI run `35169418800`：`build-package` ✓、`rork-sign-tests` ✓、**`swift-regression` ✗**，但换了一个错误 —— **95 条**同一个：

```
cannot use mutating member on immutable value: '$0' is immutable
```

全部落在 `SealTests/Installation/SelfReplacementInstallGateTests.swift` 的 `#expect` 宏展开里。

**根因**：测试写成了 `#expect(gate.acquire())`，而 `acquire()` 是 `mutating` 方法。swift-testing 的 `#expect` 是**宏**，会把表达式重写成闭包、把子表达式绑成 `$0`/`$1`…，mutating 成员作用在捕获值上编译不过。**与 §3.8 同一性质**：只在 `swift-regression` 红，`build-package` 不编译测试 target。

**修复**：

1. 把 mutating 调用提到 `#expect` 外面：`let first = gate.acquire(); #expect(first)`，并在测试文件顶部写明「为什么不能挪回去」—— 否则下一个人「顺手简化」就会复现。
2. 守卫加第二条通用检查 `#expect must not call a mutating method ...`：mutating 方法名从 `Seal/` 里**现取**（全仓只有 7 个：`acquire` / `release` / `advanceStage` / `recordInstallProgress` / 证书材料 3 个），不写死；再扫 `SealTests/**` 的 `#expect(...)` 实参里有没有 `<something>.<name>(`。同时断言「取到的 mutating 名字不少于 5 个」，防止正则漂移后变成空集 ⇒ 永远绿。
3. 变异锚点：把 `#expect(first)` 改回 `#expect(gate.acquire())`，守卫必须报红。

**顺手修掉的守卫性能问题**：加了新检查后整轮耗时从 61 秒涨到 **117 秒**，已经贴到命令默认 120 秒超时（超时会被 SIGTERM，且**没有任何输出**，极易误判成脚本崩了）。剖析结果：单遍只有 0.73 秒（× 91 遍 ≈ 66 秒），多出来的时间全在**磁盘读**上 —— 变异检查每遍都把 200+ 文件重新读一遍（≈ 2 万次），而本仓在 OneDrive 同步目录里，延迟不稳定。

对策：`main()` 里按路径缓存**基准内容**（每遍只有一个文件被替换成变异版本，走闭包里的 `changed`，不会读到缓存）⇒ **53 秒**。

⚠️ **不要**顺手把 `strip_comments` 的结果也跨遍缓存 —— 那会让被替换的那个文件读到基准版的去注释结果，变异检查静默失效（守卫全绿但什么都没检查）。这是脚本里反复警告的「绿着坏掉」。

---

### 3.10 「回主屏转场到底有没有触发」变成可观测（纯诊断，零行为变更）

**为什么还要动这一段**：CI 已在 `0da974c` 全绿，但 §6 里那条「自替换的 `stageAndInstall` 为什么不返回」仍然卡在**没有证据**上 —— `SelfInstallAutoBackground` 这条链路此前**一行日志都没有**，于是「转场到底有没有触发、是在 `installation_proxy` 返回之前还是之后触发」只能靠猜。

**读代码读出来的矛盾（2026-09-17 已由 §2.3.1 定论）**：

| 位置 | 说法 |
| --- | --- |
| `SelfInstallAutoBackground` 文档 | 「iOS 只有在旧进程退出前台后才会用新版完成替换」 |
| `MinimuxerInstallChannel`（自替换分支注释） | 「自替换也必须让 `installation_proxy` 完整返回；**提前 suspend 会冻结当前连接并留下旧 profile**」 |
| 实际触发时机 | **上传完成**（`.installing`，即上传到 100% 的 1.01 哨兵）后 **1.2 秒** —— 那时 `stageAndInstall` 显然还没返回 |

当时以为「这两套时序是冲突的」，所以**刻意不动行为**（改时序是在没有证据的情况下赌一把），只让它可观测。

> **2026-09-17 更正**：读了两份真机日志（各含两次自续签）后，冲突不成立 —— 两条注释说的是
> **同一件事的两端**：进程不退出 ⇒ iOS 不完成替换 ⇒ installd 一直等 ⇒ `stageAndInstall`
> 不返回。`MinimuxerInstallChannel` 那条注释描述的是**后果**，不是原因。
> 真正被丢掉的动作在 `.standDown`（见 §2.3.1 / §3.11）。**这一段保留原样，是因为
> 「先把日志加上、再决定动不动行为」这个顺序是对的** —— 正是这些日志让下一轮能直接否证。

**改动**：

1. `SelfInstallAutoBackground.returnToHomeAfterSealUpload(logStore:)` 接受日志出口；`AppsViewModel` 本来就持有 `logStore`，单签与批量两条链路都把**真实**出口传下去（守卫断言 `count(...) == 2`，防止只声明依赖、调用点传 `nil`）。
2. 入口、`.standDown` / `.triggerTransition` / `.waitForForeground` 三个分支、以及 `exit(0)` 兜底各留一条日志，**每条立刻 `flush()`**。
3. 「即将触发转场（suspend）」这条**刻意写在 `triggerHomeTransition` 之前**：`suspend` 一旦生效进程即被冻结，之后写的日志出不来。

**下一份真机日志即可判定**（2026-09-17 已判定，见 §2.3.1；判定过程保留在下面）：

```
安装  开始自替换安装：com.mjorb.seal.…，包 xx MB，第 1/3 次，等待上限 N 秒
安装  自替换安装仍在等待：已等待 15 秒（installd 安装阶段不回报进度）
Seal 自替换：上传完成，1.2 秒后判断前台状态并回主屏      ← 新增
Seal 自替换：触发回主屏转场（suspend）                  ← 新增
安装  自替换安装调用已返回：…                          ← 若永不出现 ⇒ suspend 确实截断了安装
```

- **最后一条永不出现** ⇒ 与安装通道的注释一致，`suspend` 冻结了承载安装的连接；
- **它出现在转场之前** ⇒ 安装调用确实返回了，问题在 AFC / installd 一侧。

> 实际结果：**「触发回主屏转场（suspend）」这一行压根没出现**（当时日志尚未加上，
> 是从「进程既不转场也不退出」否证出来的）—— 所以既不是「`suspend` 截断」，
> 也不是「AFC/installd 卡住」，而是动作根本没走到这里。详见 §2.3.1。

**守卫**：新增 3 条断言 + 3 个变异锚点 —— ①这条链路必须真的写日志且 `flush()`；②「触发转场」的日志必须排在 `triggerHomeTransition` **之前**（**断顺序，不断文案**：用 `branch.index(a) < branch.index(b)`）；③两条链路的调用点都必须传真实出口。

同时把 `.standDown` 的断言从拼接式（`"case .standDown: return false"`）改成 `section()` 切分支后断语义 —— 插一条日志就让拼接式断言失效，而那种失败信息看着像「语义坏了」，实际只是文案挪了位置。

> ⚠️ **2026-09-17 追加**：当时那版语义断言是 `"return false" in branch and "exit(0)" not in branch`，
> 而 §3.11 把 `.standDown` 改成了「该强杀」，两半都失效。重写时又踩到同一类坑的**变体**：
> 一度写成 `"exit(0)" in stand_down`，而那是这段**日志文案**里的字（「强制 exit(0) 让 iOS 完成替换」）——
> 删掉真正的 `return` 时它照样通过。现在断的是结构：`guard outcome == .wait else` +
> `return }` + 真的 `backgroundPollNanoseconds` sleep。**文案是给人看的，不是给守卫看的。**

**顺带修掉一处会污染诊断日志的重复触发**：批量链路的「回主页」此前没有 `.restart` 闸门（`if stage == .installing` 未按首次进入过滤）。`.installing` 会被**重复推送**（安装通道的 >1.0 哨兵 + 签名侧补发），所以会排出多个「回主页」任务 —— 这种重复本身是良性的（第一个任务转场后进程被挂起，后续任务不执行；转场失败时第一个 `exit(0)` 已结束进程），但**每个任务都会写一遍「上传完成 / 触发转场」日志**，恰好把这一轮新增的那段关键时序信息淹没。

修法就是 §6 里早就写下的那句「让 `BatchRefreshSession.advanceStage` 返回 `Tick`」：

```swift
@discardableResult
mutating func advanceStage(_ stage: SigningStage, at now: Date = Date()) -> InstallStageTimeline.Tick

// consumeBatchEvent：
let tick = batchRefreshSession?.advanceStage(stage) ?? .clear   // 上面有 guard 保证非 nil
if stage == .installing, tick == .restart {
    SelfInstallAutoBackground.returnToHomeAfterSealUpload(logStore: logStore)
}
```

`guard batchRefreshSession != nil else { return }` 在 `consumeBatchEvent` 开头，所以加闸门**不会**引入「抽屉被关掉后不再回主页」的回归。单签那条链路本来就用同一个闸门，现在两条链路一致。

---

### 3.11 `.standDown` 不再「立即放弃」：有界等待 + 超时强杀（问题 1 的真正修复）

这是 §2.3.1 那个坐实的根因的修复，也是问题 1 的**最后一块**。

#### 改法

`waitUntilExitIsSafe`（返回 `Bool`）改成 `waitUntilItIsTimeToExit`（返回 `Void`）——
因为**它现在总会返回**（要么转场已触发，要么等到该强杀了），返回 `false` 表示
「交给 iOS、不强杀」的那条路已经不存在。

三个状态的语义：

| 状态 | 动作 |
| --- | --- |
| `.active` | 立即触发转场（不变） |
| `.inactive`（瞬时失焦，进程仍占前台，强杀会闪退） | 最多等 6 轮 × 0.5 秒 = 3 秒，然后走 `exit(0)` 兜底（不变） |
| `.background`（用户切走了 / 保活中） | **最多等 8 秒**看用户是否回到前台；回来 ⇒ 转场；等不到 ⇒ **强杀**（新） |

强杀在后台是安全的：用户在别处，看不到闪退；而**不终止进程 iOS 就永远完不成替换**。

#### 把「等多久 / 该不该放弃」抽成可测纯函数

这段判断是「再等等」与「该动手了」的分界，错了不崩、不编译失败，只在真机永久停在 93%
—— 按项目纪律必须先抽成纯函数再写单测：

```swift
enum PollOutcome: Equatable { case act, wait }

@MainActor
static func poll(for step: ReturnHomeStep, waited: TimeInterval, rounds: Int) -> PollOutcome {
    switch step {
    case .triggerTransition: return .act
    case .waitForForeground: return rounds < inactiveRetryLimit ? .wait : .act
    case .standDown:         return waited < backgroundWaitSeconds ? .wait : .act
    }
}
```

- `.inactive` 用**轮数**预算：语义是「等系统浮层消失」。
- `.standDown` 用**总时长**预算（8 秒）：语义是「等用户回来」。
- **两条都有界** —— 无限等只是另一种形式的永久卡住。

`waitUntilItIsTimeToExit` 每个分支要么 `return`、要么 `sleep`，所以既不会忙循环，也一定有界。

#### 顺带修掉的两个实现细节

- **日志不能逐轮刷**：`.standDown` 每 0.5 秒轮询一轮，8 秒就是 16 行。改成只写第一轮，
  否则刚做的可观测性又被自己淹没。
- **局部变量不能叫 `step`**：`let step = step(for:)` 会让右侧解析到尚未初始化的局部变量，
  直接编译失败（`use of local variable 'step' before its declaration`）。改名 `currentStep`。

---

## 4. 守卫与测试

`Scripts/verify-release-safety.py`：

- 新增 **R10**（安装阶段「看得见、退得出」）：24 条断言 + 16 个变异锚点，覆盖
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
- **新增通用检查 `#expect must not call a mutating method ...`**（见 §3.9）：mutating 方法名从 `Seal/` 里现取，再扫 `SealTests/**` 的 `#expect(...)` 实参。
- **批量链路的「回主页」必须带 `.restart` 闸门**（见 §3.10）：`.installing` 重复推送时不得排出第二个「回主页」任务。
- **「回主屏」链路的日志**（见 §3.10）：这条链路必须真的写日志且 `flush()`；「触发转场」的日志必须排在 `triggerHomeTransition` **之前**（断顺序，不断文案）；两条链路的调用点都必须传真实日志出口（`count(...) == 2`）。
- **`.standDown` 不得「立即放弃」**（见 §3.11）：该分支必须同时有 `guard outcome == .wait else`、`return }` 与真的 `backgroundPollNanoseconds` sleep —— **刻意不断言 `"exit(0)" in stand_down`**：这段的日志文案里正好含「强制 exit(0)」字样，那是文本巧合不是控制流，删掉真正的 `return` 时它照样通过（绿着坏掉）。
- **轮询预算 `poll` 必须三个分支都有界**（见 §3.11）：`.triggerTransition → .act`、`.waitForForeground` 按轮数、`.standDown` 按总时长；并钉住常量 `backgroundWaitSeconds = 8`（改成 0 会让转场来不及触发，改成极大等于「永远等」）。
- **单测必须真的覆盖 `poll` 的边界**（`waited: 0 == .wait`、`everyStateEventuallyActs`）—— 否则「测试被删空」后守卫仍然全绿。
- **R09 通用化**：把「实参标签顺序必须与声明一致」做成可复用校验，覆盖 `AppRecord` / `signAndInstall` / `installSignedIPA` / `installCachedSignedIPAIfPossible`，并**断言扫到的调用点数下限** —— 本轮第一版正则把真实调用点（`coordinator.signAndInstall(`，前一个字符是 `.`）全部排除，变成「零调用点 ⇒ 零错误 ⇒ 绿」。
- 新增 `squash()`：把多行代码压成一行式断言，不再在守卫里拼换行符 + 数缩进空格（缩进一改守卫就会莫名其妙地红）。
- 修掉守卫自身的性能问题：每遍（= 每个变异）内缓存 `load` / `strip_comments`，`rglob` 结果进程内只算一次。**2 分 47 秒 → 48 秒**（此前已慢到被默认命令超时 SIGTERM，表现为「无输出、exit 1」）。

新增测试：

- `SealTests/Signing/InstallStageBridgeTests.swift`（2 条）：哨兵排他性、`enabled == false` 时不补发。
- `SealTests/Renewal/BatchRefreshSessionTelemetryTests.swift`（5 条）：只在 `.pushing` 采信百分比、越界钳制、安装起点只记一次、离开安装阶段清空遥测。
- `SealTests/DesignSystem/InstallWaitNoteTests.swift`（2 条）：`m:ss` 格式化与负数钳制。
- `SealTests/Apps/SelfInstallAutoBackgroundTests.swift`（10 条）：`.inactive` 必须 `.waitForForeground`（问题 1 的根因回归）、只有 `.background` 允许 `.standDown`、未知状态按「还在前台」处理、穷举「全部已知状态里恰好一个走 `.standDown`」；**`poll` 的边界**（见 §3.11）——`.standDown` 在 `waited == 0` 时必须是 `.wait`（**旧实现这里是「立即放弃」**）、8 秒处翻成 `.act`、`.inactive` 在 6 轮处翻成 `.act`、以及穷举「每个状态在预算耗尽后都必须 `.act`」。
- `SealTests/Signing/InstallStageTimelineTests.swift`（5 条）：首次进入安装阶段记起点、重复推送不重置、其它阶段一律清空、`.keep` 不会凭空补一个起点、批量链路与共享规则一致。
- `SealTests/Installation/SelfReplacementInstallGateTests.swift`（4 条）：已有安装在进行时第二笔必须被拒、安装结束后解锁、**超时不解锁**、连续超时永不重开。
- `SealTests/Concurrency/HardTimeoutTests.swift` 补 1 条：`cancelsWorkOnTimeout: false` 时**工作所在任务**的 `Task.isCancelled` 仍为 `false`（断言必须打在 `HardTimeout` 自己创建的那个任务上 —— 在闭包里再套一层 `Task.detached` 就会测到新任务，测试会退化成永远通过）。

结果：**214 源码断言 + 97 变异 PASS**，耗时约 54 秒。（旧断言 `count("if Self.isTimeoutInstallError(error) {") == 2` 因两个 `install` 重载合并成一份而降为 `1`，已同步改为「唯一的重试循环必须把超时当终态」。）

---

## 5. 待真机验证

1. 批量续签：抽屉显示上传百分比；上传完成立即从「传输中」变「安装中」并出现「已等待 m:ss」。
2. 单签续签：进入安装阶段（93%）后出现等待说明而不是一片空白。
3. 运行中点「取消」/「取消续签」：界面立即关闭，日志出现 `SEAL-SIGN-012` / `SEAL-RENEW-011`，列表刷新后能看到真实结果。
4. Seal 自续签：在下拉控制中心（`.inactive`）之后仍能完成替换，不再停在 93%。
5. 批量续签普通 App：确认不再出现长时间停在「传输中」的项。
6. Seal 自续签：进入安装阶段后点「取消」关掉抽屉，Seal **仍能完成替换**（触发点已在状态层，不随界面消失）—— 这条正是上一轮补修的缺陷（§3.6）。
7. Seal 自续签：导出日志应能看到**两条链路的完整轨迹**（§3.10 加了「回主屏」那段，§3.11 加了后台分支）：
   ```
   安装  开始自替换安装：…，第 1/3 次，等待上限 N 秒
   安装  自替换安装仍在等待：已等待 15 秒（installd 安装阶段不回报进度）
   Seal 自替换：上传完成，1.2 秒后判断前台状态并回主屏
   ├─ 用户还在看 App：
   │    Seal 自替换：触发回主屏转场（suspend）
   └─ 用户已切走（保活中）：
        Seal 自替换：当前在后台，等待回到前台再触发转场（最多 8 秒）
        ├─ 回到前台 ⇒ Seal 自替换：触发回主屏转场（suspend）
        └─ 没回来   ⇒ Seal 自替换：在后台等待 8 秒仍未回到前台，强制 exit(0) 让 iOS 完成替换
   安装  自替换安装调用已返回：…        ← 成功
   安装  自替换安装等待超时：…          ← 有界失败
   ```
   **这条是排查入口**：无论成功还是失败，日志都能指出卡在哪一段（上传 / installd / 回主页转场）。
8. Seal 自续签（**本轮修复的主验证项**）：把 App 切到后台再等它自己完成替换。
   修复前这条路径会「什么都不做」（§2.3.1），现在应该看到上面那条「当前在后台，等待回到前台…」，
   并在 8 秒内出现「触发回主屏转场」或「强制 exit(0)」，随后 Seal 重新打开时已是新版。
   如果仍然卡在 93%，把日志发回来 —— 里面有完整的判定依据。

---

## 6. 未解决 / 待决策

| 项 | 现状 | 需要的动作 |
| --- | --- | --- |
| 安装/上传超时预算偏长 | `mergedTimeout = min(1800, 180 + ipaMB×5) + 600`，20MB 包 ≈ 878 秒 | 是否缩短需用户拍板。缩短的代价是慢设备上的假超时：超时按**确定性拒绝**处理且不重试，但底层安装可能仍在跑 ⇒ 「装上了却记为失败」 |
| ~~批量链路的「回主页」没有 `.restart` 闸门~~ | **已修（§3.10）**：`consumeBatchEvent` 里 `if stage == .installing` 未按首次进入过滤 | 原先评估为**良性**（第一个任务触发转场后进程被挂起，后续任务不会执行；转场失败时第一个 `exit(0)` 已结束进程），但**每个任务都会写一遍「上传完成 / 触发转场」日志**，把真机排查最关键的那段时序信息淹没。已让 `BatchRefreshSession.advanceStage` 返回 `Tick`，批量链路与单签对齐 |
| 问题 1 的**调用侧**证据 | 已坐实：真机日志里普通 App 安装 7 秒完成（`16:59:06→16:59:13`），而 Seal 自替换在 `16:53:57` 之后 93 秒无任何安装结论、进程仍活着且从未被替换 ⇒ 自替换的 `stageAndInstall` **没有返回**（§2.5） | 已通过看门狗把「永久卡住」变成「有界失败 + 可查日志」。剩下的只是下一轮真机日志复核 |
| 自替换的安装调用**为什么不返回** | **已定位并修复（§2.3.1 / §3.11）**：不是 `suspend` 截断了安装，而是 `.standDown` 分支在 App 处于后台时**直接放弃**，进程既不转场也不退出 ⇒ iOS 不完成替换 ⇒ installd 一直等 ⇒ `stageAndInstall` 一直不返回。已改成「有界等待 + 超时强杀」 | 推理链完整（两份真机日志的**否证**：`suspend` 生效会冻结进程、`exit(0)` 执行会终止进程，两者都没发生），但**仍需真机确认**：第 8 项那条路径跑通即坐实 |
| ~~`MinimuxerInstallChannel` 与 `SelfInstallAutoBackground` 的时序矛盾~~ | **已澄清（§2.3.1）**：那条注释描述的是「进程不退出 ⇒ 安装不返回」的**后果**，不是原因。两者方向一致，不冲突 | 无需改动 |
| 问题 6 | 用户消息被截断（「6、签名、续签」） | 待用户补完 |
