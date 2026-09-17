# 续签链路：设备端描述文件堆积 + 序列号/UUID 版式

日期：2026-09-16
输入：用户反馈 6 条（其中第 6 条消息被截断）+ StikDebug「App Expiry」页两张截图
结论性质：**1 个真 bug（设备端 profile 只增不减）+ 1 处版式统一**；另有 2 条待日志定位

---

## 一、现象与证据

### 1.1 截图读到的真机状态

用户发的两张截图来自 **StikDebug** 的「App Expiry」页 —— 不是 Seal 的界面
（Seal 只有 Apps / Settings 两个 Tab，截图里是 Apps / Tools / Settings 三个；
`App Expiry` / `Other Profiles` / `Most Recent Profile` 三个字符串在 Seal 代码里一处都搜不到）。
但它通过 misagent 读的是**设备真实的 profile 库**，所以数据可信：

| 分组 | Bundle ID | 设备端 profile 数 |
|---|---|---|
| LiveContainer | `com.kdt.livecontainer.seal.3432ZHJUF9` | 3（1 最新 + 2 旧） |
| **Seal** | `com.mjorb.seal.CT8QZ7352B` | **17（1 最新 + 16 旧）** |
| Other Profiles | `com.kdt.livecontainer.seal666.ShareExtension` | ≥ 6（同一天 01:21–12:58） |

用户原话「目前 seal 有 16 个 UUID 对应的文件了」= 界面上的「Show 16 older profiles」。

### 1.2 这些是过期时间，不是创建时间

列表里的 `2026-09-17 12:58:53` 这类时间是**到期日**；免费账号 profile 有效期 7 天，
反推创建时间是 `2026-09-10`。也就是说：**同一天内重签了 6 次以上**，每次留一份新 profile，
旧的从不删除。

---

## 二、根因：两条独立的泄漏路径

清理代码本来就存在（`DeviceProfileCleaner`），但**触发条件**和**匹配范围**都有缺口。

### 2.1 缺口 A：只按主 Bundle ID 匹配，扩展从来没被清理过

`SigningCoordinator.removeStaleProfiles(signedData:effectiveBundleID:)` 原本是：

```swift
guard let profileUUID = SignedArtifactProfileReader.embeddedProfileUUID(in: signedData) else { return }
Task {
    await DeviceProfileCleaner.removeStaleProfiles(for: effectiveBundleID, keeping: profileUUID)
}
```

`SignedArtifactProfileReader` 只认**恰好三段**的路径
（`Payload/<App>.app/embedded.mobileprovision`），也就是只读主 App 那一份。
而一次安装会为**每个扩展**各装一份 profile。

后果：抖音 8 扩展 → 9 份 profile，只有主 App 那份会被清理；LiveContainer 的
ShareExtension 那份从头到尾没人管 —— 截图里那 6 份就是这么来的。

### 2.2 缺口 B：只在安装成功那一刻触发，历史堆积清不掉

清理只挂在 `installSignedIPA` 成功之后。`AppMaintenanceJob`（空闲维护作业）
**完全没有描述文件清理这一步**，它的三步是：记录恢复 → Seal 自身注册 → 孤儿文件清理。

所以即使修好缺口 A，也只能阻止「以后不再堆」，已经堆起来的 16 份永远不会被回收。
Seal 自己的自更新走的是 `SelfReplacementCoordinator` 事务链，不是 `installSignedIPA`，
它的清理依赖 `SelfAppRegistrar` 的结算路径，条件更严（要求运行身份与事务记录一致），
更容易整批跳过。

---

## 三、已实施的改动

### 3.1 `SignedArtifactProfileReader.embeddedProfiles`

新增枚举**全部**会被 iOS 安装为独立 profile 的位置：

```swift
private static func isInstalledAppProvision(_ path: String) -> Bool {
    let segments = path.split(separator: "/")
    guard segments.count >= mainProvisionSegmentCount,
          segments[0] == "Payload",
          segments[segments.count - 1] == "embedded.mobileprovision" else { return false }
    return segments[segments.count - 2].hasSuffix(".app")
}
```

覆盖 `Payload/<App>.app/`、`Payload/<App>.app/PlugIns/<Ext>.appex/`、AppClips、Watch；
**刻意排除** `Frameworks/*.framework/embedded.mobileprovision` —— framework 的 profile
不会被 installd 装成设备 profile，算进保留集合等于给那个 Bundle ID 发一张
「永远不许清理」的免死金牌。

Bundle ID 取自 profile 自身的 `application-identifier`（已剥 TeamIdentifier 前缀），
不从路径推断 —— 路径名与真实 Bundle ID 不一定一致。

### 3.2 `DeviceProfileCleaner` 改为「保留映射」

```swift
static func removeStaleProfiles(keepingByBundleID: [String: String]) async -> ProfileCleanupSummary
```

key 是「Seal 管理的 Bundle ID」，value 是「该 Bundle ID 当前在用、必须保留的 UUID」。
**key 集合之外的一律不碰** —— 设备上还有 MDM 配置描述文件、企业证书签的 App、
其它工具装的 App，它们不在 Seal 的记录里，误删会让那些 App 直接无法启动。

### 3.3 `AppMaintenanceJob` 新增第 4 步

```swift
// ── 4. 设备端旧描述文件清理（设备删除，最佳努力）─────────────────
let profileOutcome = await sweepStaleProfiles(token: token)
```

放在最后：保留集合来自 `AppRecord`，而前三步（记录恢复 / 自注册 / 孤儿清理）
正是把记录修正到位的过程。

**这一步是清掉历史堆积的关键** —— 它不依赖某一次安装成功，只要记录里写着
「这个 Bundle ID 现在用的是哪一份」，其余同 Bundle ID 的都会被删。

### 3.4 两条安全红线（都有守卫锁住）

**红线 1：拿不到可信 UUID 就整条跳过。**

```swift
guard let uuid = record.provisioningProfileUUID, Self.isBlank(uuid) == false else { continue }
```

宁可留着旧 profile（只是占地方），也绝不能猜「保留最新那份」。
iOS 启动时会校验 profile 是否还在设备上 —— 删错一份，那个 App 立刻无法启动。

**红线 2：扩展记录是乐观值，只有安装校验通过才采信。**

```swift
guard record.signedArtifactStatus == .installed else { continue }
for extensionRecord in record.extensions { ... }
```

`SigningCoordinator.applySigningResult` 在**签名阶段**就把扩展的 UUID 改成新产物的
（顶层 `provisioningProfileUUID` 反而要等安装校验通过才推进，见 `SignedArtifactSnapshot` 的 R08 约定）。
所以「签名成功但安装失败」时，扩展记录指向的是一份设备上并不存在的 profile ——
拿它当保留集合，会把真正在用的那一份删掉，扩展当场失效。

Seal 自己则以**运行时读到的真实 profile** 覆盖记录值（记录可能落后于现实）。

### 3.5 版式统一（问题 3/4）

证书序列号与描述文件 UUID 由上下两行改为**左右一行**，超长中间省略：

```swift
HStack(alignment: .firstTextBaseline, spacing: 14) {
    Text(title).foregroundStyle(.primary).lineLimit(1)
    Spacer(minLength: 12)
    Text(value)
        .font(.system(.caption, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .trailing)
}
```

统一到 5 处：`AppDetailView.serialDetailRow` / `profileDetailRow`、
`InstalledAppActionSheet.metadataValueRow`、`AppSigningSheet.summarySerialRow`、
`SigningProgressView.runtimeSerialRow`。

---

## 四、守卫与测试

- `Scripts/verify-release-safety.py` 新增 **R08**（5 条断言）+ **3 个变异锚点**
  - 变异 1：`isInstalledAppProvision` → `isMainProvision`（退回只清理主 App）
  - 变异 2：把 `guard let keepingUUID = ...` 换成 `?? ""`（key 外也参与删除）
  - 变异 3：把扩展的安装门槛换成 `guard true`（采信乐观值）
  - 变异 4：把 `guard let uuid = record.provisioningProfileUUID` 换成 `?? ""`（猜保留哪份）
- 顺带修正了一处**被自己削弱**的既有断言：`C: the sweep must re-check the lease`
  原本是 `"..." in job`，现在有两处删除步骤（孤儿清理 / 描述文件清理），
  删掉其中一处仍会被另一处掩盖 → 改为按出现次数断言（`>= 2`）。
- 新增用例：`AppMaintenanceJobTests` 4 条（保留集合只收有记录的应用 / Seal 运行时值覆盖记录 /
  空白值忽略 / 租约失效时一份都不删 / 扩展仅在安装确认后采信）、
  `SignedArtifactProfileReaderTests` 4 条（主+扩展都收 / 排除 Frameworks / 同 UUID 去重 / 无 profile 返回空）。

结果：`147 source checks + 64 mutation checks` **PASS**。

---

## 五、待验证（需真机）

本机（Windows）无 Swift 工具链，编译验证依赖 CI。

1. CI 三 job 全绿：`build-package` / `swift-regression` / `rork-sign-tests`
2. 真机：打开 Seal 静置片刻（触发空闲维护），再看 StikDebug 的 App Expiry 页 ——
   - Seal 自己应从 17 份降到 1 份
   - 日志里应出现 `设备端旧描述文件清理：扫描 N，匹配 M，删除 K`（`SEAL-PROFILE-320`）
   - 若出现 `skipped-record-read-failed` 或 `stage=dump`，说明隧道/misagent 通道没起来
3. 真机：续签一个带扩展的 App（如 LiveContainer），安装后检查扩展的旧 profile 是否被清

---

## 六、尚未解决（需要日志）

| # | 问题 | 状态 |
|---|---|---|
| 1 | 续签到安装步骤卡在 93% 无反应 | 93% = `.installing`（`SigningProgressView:212`）。`installTimeout = 600s`、`pushTimeout ≈ 180 + ipaMB×5`（19.7MB → 278s），所以「卡住」可能长达 4.6–10 分钟。**需要卡住那一刻前后 1 分钟的 Seal 日志** |
| 2 | 续签抽屉卡在「传输」无反应 | 「传输」= `.pushing`。注意：抽屉里 Seal 那一项应显示「即将更新」而非「传输中」，卡在「传输中」的大概率不是 Seal |
| 6 | 消息被截断（「6、签名、续签」） | 待用户补完 |

另外两个可选改进待用户决定：
① 安装超时 600s → 180s；② 传输阶段加进度停滞检测。

---

## 七、2026-09-17 复查：上轮的修复**没有生效**，而且原因不止一个

重新读了用户此前导出的全部 `Seal-log*.txt`（19 份），把「描述文件清理」相关的日志行全部捞出来，
一共只有 8 条 —— 数量少得反常，正好说明了问题。

### 7.1 全部 8 条日志（原文）

| 时间 | 日志 | 链路 |
|---|---|---|
| 09-14 20:43:32 | `安装后旧描述文件清理（com.sollinplayer.leguan.seal.Q88QMP4DLM）：扫描 30，匹配 2，删除 1` | 安装后 |
| 09-14 20:43:52 | `自更新安装前清理：扫描 29，匹配 3，删除 3` | 旧构建（该文案现已不在源码里） |
| 09-14 20:45:14 | `自更新安装前清理：扫描 28，匹配 1，删除 1` | 旧构建 |
| 09-15 11:46:02 | `安装后旧描述文件清理（com.kdt.livecontainer…）：扫描 325，匹配 1，删除 0` | 安装后 |
| 09-15 11:46:55 | `安装后旧描述文件清理（com.stik.stikdebug…）：扫描 326，匹配 1，删除 0` | 安装后 |
| **09-16 16:59:28** | `安装后旧描述文件清理（com.kdt.livecontainer…）：扫描 0，匹配 0，删除 0，中断于 dump，首个错误：NoDevice` | 安装后 |
| 09-16 20:55:42 | `安装后旧描述文件清理（com.sollinplayer.leguan…）：扫描 23，匹配 2，删除 1` | 安装后 |
| 09-16 21:07:38 | `安装后旧描述文件清理（com.example.kazumi…）：扫描 23，匹配 1，删除 0` | 安装后 |

**关键否定证据：`设备端旧描述文件清理：` 一次都没出现过。**

这条日志是 `AppMaintenanceJob` 第 4 步（`SEAL-PROFILE-320`）**无条件**写的，
而 `系统` 类别在导出里确实存在（9 条）⇒ 不是导出过滤掉了。

⚠️ **但「零命中」在这里有第二个、更简单的解释**：那个构建里**根本没有第 4 步**。
`git show 0c16174:Seal/Core/Maintenance/AppMaintenanceJob.swift | grep -c profileSweeper`
= **0** —— 维护第 4 步是 run#79（`bc069e3`）才进去的，而用户的构建 ≤ run#75。
所以这一条的零命中**不构成证据**（详见 §7.6）。

**仍然成立、且是本节结论的那一半**：第 4 步恰恰是 §3.3 里说的「清掉历史堆积的关键」
—— 它是唯一覆盖**全部** Seal 管理 App 的路径。而它在用户设备上**一次都没跑过**，
原因就是它不在那个构建里。

### 7.2 为什么没跑，原先查不出来

`AppsViewModel.runMaintenanceIfIdle()` 的 `switch outcome` 里：

- `.completed` → 有日志（`SEAL-STORAGE-005` / `008` / `SEAL-PROFILE-321`）
- `.aborted` → 有日志（`SEAL-STORAGE-006`）
- **`.skipped` → 只有一句 `break`，不写日志**
- **`.failed` → 只弹窗（`alertFailure = failure`），不写日志**

`.skipped` 的成因是 `MaintenanceGate` 返回 nil（有前台操作在进行）—— 这是**设计意图**
（低优先级、可抢占、永不阻塞用户操作），但代价是「这一轮到底跑没跑」完全无法回答。
用户看到的就是「profile 一直在堆」，而日志里连一行都找不到，看起来像清理逻辑根本不存在。

### 7.3 第二条静默路径：自替换结算清理只写事务、不写日志

`SelfAppRegistrar.reconcileSelfReplacement` 里，结算成功后调用
`profileCleaner.removeStaleProfiles(request)`，摘要交给
`selfReplacement.finishCleanup(cleanup)` → `store.close(cleanupSummary:)`，
**只落进事务审计文件**。

这是**唯一**会回收 Seal 自己那份堆积的路径 —— Seal 的自更新不走 `installSignedIPA`，
所以 §7.1 那 8 条「安装后旧描述文件清理」根本轮不到它。
而截图里 Seal 自己堆了 17 份（1 最新 + 16 旧）。

事务审计只在 App 内部可读；真机排障时能拿到的只有**导出的日志**。
所以「自替换清理有没有跑、是不是被判成 `skipped-identity-changed`」在日志里查不到任何线索。

### 7.4 三处修复

**A. dump 阶段有界重试**（`DeviceProfileCleaner`）

`Provision.dumpProfiles` 内部走 `Device.getFirstDevice()`，轮询
`MuxerConstants.deviceFetchTimeoutMs`（**15000 ms**）后抛 `NoDevice`。
`16:59:28` 那条的 15 秒间隔与它完全吻合 ⇒ **一次都没重试**就整轮放弃。

而两个触发点的时机都不保证设备已连上：安装后清理紧随安装（RSD 连接可能正在重建），
维护期清理在 App 启动时（LocalDevVPN 隧道可能还没起来）。

```swift
private static let dumpAttemptLimit = 3
private static let dumpRetryDelayNanoseconds: UInt64 = 4_000_000_000

private static func dumpProfiles(docsPath: String) async throws -> (path: String, attempts: Int) {
    for attempt in 1...dumpAttemptLimit {
        if attempt > 1 {
            // 先重置再等：重置拆掉缓存的死连接，等待让 RSD / 隧道有时间恢复。
            Provision.resetProvider()
            try? await Task.sleep(nanoseconds: dumpRetryDelayNanoseconds)
        }
        do {
            return (try Provision.dumpProfiles(docsPath: docsPath), attempt)
        } catch {
            if attempt == dumpAttemptLimit { throw error }
        }
    }
    throw MinimuxerError.NoDevice
}
```

最坏耗时 ≈ 3 × 15 + 2 × 4 ≈ 53 秒，但整段在后台任务里，不阻塞任何前台操作。

**`Provision.resetProvider()` 不能省**：provider 可能缓存着一条已经断开的 RSD 连接，
不重置的话三次重试全走同一条死路，等于没重试。

**B. 维护作业每个非 `.completed` 结果都留痕**

| 分支 | 新增日志码 |
|---|---|
| `.skipped` | `SEAL-STORAGE-009` — 「维护作业本轮跳过：有前台操作正在进行」 |
| `.failed` | `SEAL-STORAGE-010` — 「维护作业失败：…」 |

**C. 自替换结算清理落日志**（`SelfAppRegistrar`）

```swift
try? await logStore?.append(
    category: .installation,
    message: "自替换结算清理：\(cleanup.logMessage)",
    code: "SEAL-PROFILE-322"
)
```

写在 `finishCleanup(cleanup)` **之前**：摘要进事务审计只是副作用，日志才是排障入口。

**D. 摘要新增 `dumpAttempts` 字段**

```swift
/// dump 阶段实际尝试了几次（含首次）。> 1 说明前几次撞上了设备不可达。
var dumpAttempts = 1
```

`logMessage` 里只在 `> 1` 时输出「，dump 尝试 N 次」—— 绝大多数清理一次就成功，
逐条都带「尝试 1 次」只是噪音。

### 7.5 守卫与测试（本轮增量）

- `Scripts/verify-release-safety.py`：**222 源码断言 + 102 变异**（此前 214 + 97），约 69 秒
  - 新增 R08 断言：重试预算值、重试体必须含 `resetProvider` + `sleep`、
    调用点必须走包装（`Provision.dumpProfiles` 不得出现在 `removeProfiles` 里）、
    `summary.dumpAttempts = dump.attempts`、维护三个非 `.completed` 分支各自的日志码、
    自替换清理日志必须排在 `finishCleanup` 之前
  - 新增 7 个变异锚点：重试次数改回 1 / 去掉 `resetProvider` / 绕过包装直接调 FFI /
    `.skipped` 改回 `break` / `.failed` 去掉日志 / 自替换去掉日志 / 两处「单测被改宽」
- 新增单测：
  - `SealTests/Installation/DeviceProfileCleanerTests.swift`（**新文件，6 条**）——
    摘要文案的信息量。这是清理唯一的排障通道，字段少一个就退回「一片空白」。
  - `SelfAppPendingHandoffTests.confirmedReplacementLogsCleanupSummary`（1 条）——
    断言日志**真的落下来了**（源码断言证明不了 `logStore` 被注入、消息没被脱敏吃掉）。

### 7.6 更关键的一层：**那份日志来自一个比修复更早的构建**

上面 §7.1–§7.5 的分析有个隐含前提 —— 「日志反映的是当前代码的行为」。这个前提**不成立**。

线索是日志文案与源码对不上：日志里是

```
安装后旧描述文件清理（com.kdt.livecontainer.seal.3432ZHJUF9）：描述文件清理：…
```

而当前源码（`SigningCoordinator.swift`）是

```swift
message: "安装后旧描述文件清理（主 \(effectiveBundleID)，共 \(keepingByBundleID.count) 个 Bundle ID）：\(summary.logMessage)"
```

**`主 ` 与 `共 N 个 Bundle ID` 在所有日志里一次都没出现过。**

#### 怎么把「文案差异」变成「构建号」

`Scripts/build-unsigned-ipa.sh:33`：

```bash
CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-${SEAL_BUILD_NUMBER:-1}}"
```

**构建号 = GitHub Actions 的 run number** ⇒ 唯一对应一次 CI 构建 ⇒ 唯一对应一个提交。
而安装失败时的诊断信息里本来就会打 `Seal构建\(CFBundleVersion)`（如 `Seal构建61`）。

拿文案去比对历史提交，得到一条清晰的分界线：

| CI run | 提交 | 构建时间（北京） | `安装后旧描述文件清理` 的文案 |
|---|---|---|---|
| run#73 | `aba93cc` | 09-16 19:23 | `（<bundleID>）` ← 旧 |
| run#75 | `0c16174` | 09-16 22:49 | `（<bundleID>）` ← 旧 |
| **run#79** | **`bc069e3`** | **09-17 00:48** | `（主 <bundleID>，共 N 个 Bundle ID）` ← **新** |

而用户最新的一份日志（`Seal-log(2) (1).txt`）**最后一条是 09-16 21:56**。

> **结论：用户的构建 ≤ run#75，早于 run#79。**
> 也就是说 §3.1/§3.2（扩展 profile 覆盖）**从未在真机上运行过**，
> 今天（09-17）的三处修复更是无从谈起。

这解释了为什么 §7.1 里那些「修复没生效」的观察会那么干净 —— 因为那些修复**根本不在那个构建里**。

#### 那么「六个日志码零命中」到底能推出什么

`AppMaintenanceJob.run()` 会留下这些日志码。**但必须先把「这个码在用户那个构建里存不存在」
查清楚** —— 否则「零命中」只能证明代码不在，证明不了路径没跑：

| 码 | 触发条件 | run#75 里存在？ | 19 份日志命中 |
|---|---|---|---|
| `SEAL-STORAGE-005` | 孤儿目录清理有删除 | ✅ | 0 |
| `SEAL-STORAGE-006` | 作业被用户操作打断（`.aborted`） | ✅ | 0 |
| `SEAL-STORAGE-008` | 有导入事务目录被跳过 | ✅ | 0 |
| `SEAL-PROFILE-320` | 第 4 步跑到就写（无条件） | ❌ **不存在** | 0 |
| `SEAL-PROFILE-321` | 描述文件清理有删除 | ❌ **不存在** | 0 |
| `SEAL-SELF-REG-001` | 自注册失败 | ✅ | 0 |

用 `git show <sha>:<file> | grep <码>` 核对 `aba93cc`(run#73) / `0c16174`(run#75) / `bc069e3`(run#79)：

- **`SEAL-PROFILE-320` / `sweepStaleProfiles` / `profileSweeper` 在 run#73、run#75 里都是 0 处**
  ⇒ **维护第 4 步在用户的构建里根本不存在**。它的零命中是**平凡结论**，不构成任何证据。
- `SEAL-STORAGE-006` 在 run#75 里**存在**且零命中 ⇒ 维护作业**从未被打断**过（这一条有效）。
- `SEAL-STORAGE-005` 在 run#75 里存在且零命中 ⇒ 只能推出「没有孤儿目录被删」，
  **推不出「作业没跑过」** —— 作业完全可能每次都 `.completed`，只是恰好没有孤儿要清。

> ⚠️ **上一轮在这里犯了本文件 §7.6 自己刚警告过的错**：拿一个**在旧构建里不存在的日志码**
> 的零命中，去论证「这条路径没执行」。**判据：任何「零命中」结论，先确认那个字符串
> 在对应构建里存在**（`git show <sha>:<file> | grep`），否则它只是平凡真。

所以用户设备上 profile 堆积的完整解释是（**不需要额外的 bug**）：

1. 那个构建里**只有**安装后清理一条路径，而它只覆盖**本次安装的那个 App**；
2. Seal 的自更新不走 `installSignedIPA` ⇒ 安装后清理**轮不到 Seal 自己**；
3. 维护第 4 步（唯一覆盖全部 App 的路径）在那个构建里**还不存在**；
4. 唯一那条路径还撞过一次 `NoDevice` 且不重试（§7.1 的 16:59:28）。

⇒ 16 份 Seal 的旧 profile 完全由此解释。

### 7.7 仍未解决（需要真机日志）

| # | 现象 | 判断 |
|---|---|---|
| 1 | 维护作业在本轮构建里到底跑不跑 | 现在有了 `SEAL-STORAGE-009`（跳过）/ `010`（失败）/ `320`（第 4 步无条件）就能区分。若长期只有 `009`，说明 `MaintenanceGate` 的抢占过于频繁（它在启动路径上、且**非阻塞**：拿不到就跳过、不排队），要把「跳过」改成「推迟」 |
| 2 | `扫描 325，匹配 1，删除 0` | **上一轮把它当成泄漏信号是过度解读** —— 那是 run#75 之前的构建，`keep-map` 只有单条（`for: bundleID, keeping: uuid`），所以 `匹配 1` 是**正常表现**。当前版本改为「主 App + 全部扩展」的多条映射后，同一行会变成 `匹配 N`。**但「堆积没有结构性来源」这个引申结论也是错的** —— 见 §7.8：多 Apple ID 轮换会生成 36 个 Bundle ID，历史 Team 后缀的 profile 当前一份都回收不了 |
| 3 | `自更新安装前清理` 的文案已不在源码里 | 09-14 那两条来自更早的构建（该文案被改过名），不影响现状 |
| 4 | `扫描 325/326`（09-15）→ `扫描 23`（09-16） | 设备上的 profile 数从 325 掉到 23，**原因不明**。用户若在此期间用别的工具清过、或删过 App，请说明一下 —— 这会改变「堆积速度」的估算 |

### 7.8 堆积的**结构性**来源：多 Apple ID 轮换 × Team 后缀（已量化）

§7.7 第 2 条否掉了「`匹配 1` 是泄漏信号」，但**不等于堆积没有结构性来源**。
2026-09-17 从 19 份日志里把所有 `.seal.<后缀>` 形态的 Bundle ID 全捞出来统计：

| base | Team 后缀数 | 后缀 |
|---|---|---|
| `com.ss.iphone.ugc.Aweme` | **6** | `32746RUBTT` `49778Q7UWQ` `6T43967CCT` `JHW8PJBRJ2` `Q88QMP4DLM` `douyin` |
| `com.mjorb`（Seal 自己） | **5** | `49778Q7UWQ` `6T43967CCT` `CT8QZ7352B` `KYRJV2U7WS` `TB95F327DS` |
| `com.sollinplayer.leguan` | 4 | `3432ZHJUF9` `6T43967CCT` `JHW8PJBRJ2` `Q88QMP4DLM` |
| `com.kdt.livecontainer` | 3 | `3432ZHJUF9` `KYRJV2U7WS` `TB95F327DS` |
| `com.dao.lara` | 3 | `3432ZHJUF9` `9DNHBHSQDU` `JHW8PJBRJ2` |
| （其余 13 个 base） | 1–2 | … |

**合计：18 个真实 base × 13 个不同 Team 后缀 = 36 个 Seal 生成过的 Bundle ID。**

（统计时需剔除 6 条假 base —— iOS 在 `SEAL-INSTALL-702l` 报错里用
`<TeamID>.<BundleID>` 的格式罗列已装应用，例如
`9DNHBHSQDU.com.javdb6.com.seal.9DNHBHSQDU` 里的 `9DNHBHSQDU.com.javdb6.com`
是 iOS 加的前缀，不是套娃。真实 ID 是 `com.javdb6.com.seal.9DNHBHSQDU`。
**注意别把它误判成「Team 后缀套娃」这个不存在的 bug。**）

**为什么会换这么多 Team**：同一份日志的 `SEAL-INSTALL-702l` 写着
`This device has reached the maximum number of installed apps using a free developer profile`，
并列出 3 个同属 team `9DNHBHSQDU` 的应用 ⇒ 用户在用**多个 Apple ID 轮换**来突破
免费账号「3 个自签应用」上限。每换一个账号（= 换 team），Seal 就会给每个 App 生成一个
**新的 Bundle ID**（`BundleIDMapper` 强制附加当前 team 后缀）。

**这直接决定了堆积的量级**：36 个 Bundle ID × (1 主 + 若干扩展) ≈ 至少 36–72 份 profile，
再叠加每次重签换新 profile UUID，与实测「扫描 325」完全吻合。

**而当前代码一份都回收不了这些**：`profileKeepMap` 的 key 只有**当前**在用的 Bundle ID
（`mappedBundleIdentifier ?? preferredBundleIdentifier` + 已安装记录的扩展），
`removeProfiles` 里 `guard let keepingUUID = keepingByBundleID[profileBundleID.lowercased()]
else { continue }` —— **不在 key 集合里的一律跳过**。所以历史 Team 后缀的 profile
永远不进 `matched`，`删除` 恒为 0。

这不是 bug，是**有意的保守**（删错一份会让对应 App 立刻无法启动）。要放开它，
必须先能回答「哪些 Bundle ID 是 Seal 生成的、且现在确实没在用」。→ §7.9

### 7.9 回收旧 Team profile 的设计决策（待用户拍板）

**可用的安全判据**：`Minimuxer.lookupApp(bundleId:)`（`Vendor/Minimuxer/RustBridge/
MinimuxerBridgeIdevice.swift:314`，走 `instproxy_lookup`）能查某个 Bundle ID
在设备上**是否已安装**。安装后校验已经在用它（`MinimuxerInstallChannel.swift:800`）。

⇒ 一条**无懈可击**的删除条件：**该 Bundle ID 在设备上没有对应的已安装 App**。
profile 只在 App 启动时被校验，App 没装 ⇒ 这份 profile 是死重量，删掉不可能破坏任何东西。

**但只有这一条还不够，必须再加一条保守过滤**：`AppRecord.swift:275` 明确写着
「不包含 `originalBundleIdentifier`：**同一原始 IPA 可用不同 Bundle ID 签出多个副本
同时安装**」。也就是说用户**可以**故意把同一个 App 用两个 Team 各装一份 ——
此时「同 base 的其他 Team 就是过期」是**错的**。所以：

> 删除条件 = ①Bundle ID 不在当前 keep-map **且** ②形态上属于 Seal 生成
> （`<base>.seal.<X>`，base 取自记录的 `originalBundleIdentifier`；Seal 自己单独处理，
> 它是 `com.mjorb.seal.<team>` 而非 `com.mjorb.seal.seal.<team>`）
> **且** ③`lookupApp` 返回 nil（设备上没装）。

三个条件同时成立才删。①②限定爆炸半径，③保证正确性。

**代价**：每个候选 Bundle ID 一次 installation_proxy 往返（本例约 30 个候选）。
跑在后台维护作业里，不阻塞前台。

**待决策**：见本轮向用户提出的选项（实现 / 只加诊断日志 / 维持现状）。

### 7.10 已做的配套改进：让日志自带构建号

上面那轮取证绕了很大一圈，根因是**导出的日志里没有任何构建标识**。
`SealLogTextFormatter.exportText` 的表头现在多一行：

```
Seal 日志 · 北京时间 · 保留最近 1000 条
构建 1.1.16 (91) · 构建号取自 CI run number，可用于定位对应提交
```

`currentBuildLabel` 读 `CFBundleShortVersionString` + `CFBundleVersion`；
`SealLogStore.exportText()` **显式**透传（不靠默认参数），这样守卫的源码断言看得见这条依赖。
新增 `SealTests/Diagnostics/SealLogTextFormatterTests.swift`（5 条），
其中 `storeExportIncludesBuildLabel` 走真实导出路径 —— 源码断言证明不了它真的进了文本。

