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
