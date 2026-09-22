# 2026-09-16 · 自续签体验与证书展示 7 问：检验 → 根因 → 实施 → 合理性评估

> 前置状态：自续签已可正常工作（见 DEBUG_LOG 2026-09-16 三条）。
> 本文逐条核对用户提出的 7 个问题，先定位真实根因（含文件/函数），再给实施改动、
> 「这个要求本身合不合理」的判断，以及「有没有更好的做法」。
> 所有改动已通过 `Scripts/verify-release-safety.py`（129 源码回归 + 55 变异）；
> **Swift 编译与真机回归仍需在 macOS 侧完成**。

---

## 总览

| # | 问题 | 根因性质 | 处置 |
|---|------|----------|------|
| 1 | 签名/续签卡在「正在连接设备」很久 | **真 bug**：隧道诊断被放在签名前同步等待 | 已改：并行化 + 通道单飞 |
| 2 | 「Apple ID 证书 · 序列号 xxx」显示不全 | 呈现问题：右侧单行 + `.truncationMode(.middle)` | 已改：统一「证书序列号」+ 值独占一行 |
| 3 | 自续签蓝色文案要跟普通 App 一样 | 文案分叉 | 已改：统一；安装阶段换「正在退回主屏幕」 |
| 4 | 续签后证书没关联到 Seal 自己 | **真 bug**：两处关联判定不同源 | 已改：清单复用 `associatedApps` 口径 |
| 5 | 是否真的用了 7 天新 profile（怕第二天掉签） | 代码已强校验，但**用户无法自证** | 已改：详情页暴露 profile UUID + 创建时间 |
| 6 | 续签完回主屏像闪退 | 转场不可感知 + `suspend` 失败时静默无操作 | 已改：UI 转场 + 双路径 suspend + 兜底 exit |
| 7 | 描述文件「可用」要换成该应用的 UUID | 呈现问题 | 已改：UUID 独占一行灰色；异常状态标签保留 |

---

## 问题 1 · 签名/续签卡在「正在连接设备」

### 现象
点签名/续签后，界面长时间停在「正在连接设备」，签名本身要等很久才开始。

### 根因（真 bug，不是显示问题）

`AppsViewModel.runSigning`（`Seal/Features/Apps/AppsViewModel.swift`）在调用签名协调器**之前**：

```swift
updateSigningStage(.waitingForChannel)
if completionMode == .signAndInstall {
    guard await refreshSigningChannel() else { throw Self.connectionRecoveryFailure }
}
```

`refreshSigningChannel()` → `installChannel.start()`，冷启动时会跑完整隧道诊断：
`reset()` + 最长 18s 的 RSD 握手轮询（36×500ms）+ 就绪探测，硬超时上限 75s。

而 `SigningCoordinator.signAndInstall` 里已经做过一次「连接并行化」：
`channelStart = Task { try await installChannel.start() }` 与签名并行，安装前才 await。
**那次并行化对首个调用完全无效** —— 因为 ViewModel 在更早的位置已经同步等完了整段诊断，
等 `signAndInstall` 再调 `start()` 时只是命中缓存瞬间返回。

即：诊断耗时 100% 落在 `.waitingForChannel` 这一个阶段上，而它本该与签名重叠。
`updateState(.waitingForChannel)` + `progress(.waitingForChannel)` 又把 UI 钉在「正在连接设备」。

### 已实施

1. `AppsViewModel` 新增 **非阻塞** `beginSigningChannel()`：把 `installChannel.start()`
   丢进后台 Task，立刻返回；任务结束后在 `MainActor.run` 里清句柄并落定 `signingChannelStatus`。
   `runSigning` 改为调用它，不再 `await`。
   （`resumePendingVPNAction()` 那条「用户主动点恢复连接」的路径保持同步等待 —— 那是用户显式请求。）
2. `MinimuxerInstallChannel.start()` 增加 **单飞合并**（`inFlightStart: Task<String, Error>?`）：
   现在 ViewModel 会并行发起、`SigningCoordinator` 安装前还会再 ensure 一次，
   没有单飞就会各自跑一遍完整诊断（reset + RSD 握手重复、耗时翻倍）。并发调用一律加入同一次启动。
   这也顺带修掉批量续签里潜在的重复启动。
3. `SigningCoordinator.signAndInstall` 安装前 await `channelStart` 时，**不再 `try?` 吞掉错误**：
   只有通道确实没就绪（`isReady()` 为假）才把底层诊断错误（`SEAL-VPN-*` / `SEAL-PAIR-*`）
   抛给用户；只是那一次诊断抖动则继续交给 `installSignedIPA` 的 ensure 兜底，不制造新失败面。

### 合理性评估
要求「不要卡」合理；但要注意 **不能靠缩短超时** 来「提速」——
诊断慢是设备/网络真实状态，砍超时只会把「慢」换成「误判失败」。
正确做法是**重叠**（与签名并行）而不是**加速**。

### 更好的做法（后续可选）
- 在签名阶段把 `signingChannelStatus`（`.connecting/.ready/.unavailable`）做成副标题常驻显示
  （「正在连接设备（后台进行）」），让用户知道它没死。
- `start()` 的 75s 硬超时可按「缓存命中 / 冷启动」分档。

---

## 问题 2 · 「Apple ID 证书 序列号 · xxxxxx」→「证书序列号 / 完整序列号」

### 根因（呈现）
序列号值在标题**右侧单行**渲染，并带 `.truncationMode(.middle)` 与
`.minimumScaleFactor(0.8)`：40 位十六进制（≈288pt @12pt 等宽）在 390pt 屏上
减去 96–120pt 标题后必然被截断，且「序列号 · 」前缀又白占 4 个字符。

### 已实施
- `AppSigningPresentationHelpers.certificateName(serial:)` → **`certificateSerialText(serial:)`**，
  只返回完整序列号（`fullSerial`：只留十六进制、转大写），不再带「序列号 · 」前缀。
- 行标题统一 `Apple ID 证书` → **`证书序列号`**（与其它行同样的左侧黑色主文字）。
- 值改为**独占一行**、灰色、等宽、`.fixedSize(horizontal: false, vertical: true)`、`.textSelection(.enabled)`，
  彻底不截断。四个入口全部统一：
  `AppDetailView`、`SigningProgressView`、`InstalledAppActionSheet`、`AppSigningSheet`。

### 合理性评估
合理，且比原方案更好：序列号本来就是要被「核对/复制」的字段，
独占一行 + 可选中比挤在右侧更符合用途。「去掉『序列号 · 』前缀」是必要的一步——
标题已经说明这是序列号，前缀纯属冗余占位。

---

## 问题 3 · 自续签蓝色文案与普通 App 统一

### 根因（文案分叉）
`SigningProgressView` 原来按 `sealRenewal` 二选一：

```swift
Text(sealRenewal ? sealReplacementTip : keepSealOpenTip)
// sealReplacementTip = "进度走完后请按 Home 键回到主屏幕，iOS 会用新版替换 Seal…"
```

这条 Seal 专属文案是「自动回主屏」能力上线**之前**的产物；现在 Seal 会自己退后台，
再要求用户按 Home 属于说反了。

### 已实施
- 签名/续签进行中一律 `keepSealOpenTip`（「请保持 Seal 打开，不要锁屏或切换 App。」）。
- 删除 `sealReplacementTip`，新增 `sealReturningHomeTip`
  （「正在退回主屏幕，iOS 会用新版替换 Seal；替换完成后重新打开即可。」），
  **只在 Seal 进入 `.installing` 之后**显示 —— 也就是 Seal 即将自动退后台的那一瞬。

### 合理性评估（这里要提醒一句）
「统一成同一句话」本身合理，但存在语义张力：Seal 自续签**必须**切后台，
而「不要切换 App」正是它自己要违反的动作。
所以最终方案是「分两段」：签名阶段统一成普通文案（用户什么都不用做），
安装阶段换成「正在退回主屏幕」——把 Seal 自己的动作说清楚。
如果你更希望**全程只有一句**，那就只能保留 `keepSealOpenTip` 并在文案里彻底不提回主屏；
不建议反过来把普通 App 也改成 Seal 文案。

---

## 问题 4 · 续签后证书没关联到 Seal 自己

### 根因（真 bug：两处判定不同源）

证书卡片里同一张证书有两处展示，用的却是**两套关联规则**：

| 位置 | 函数 | 规则 |
|------|------|------|
| 行标签「本机已安装 App 在用」 | `CertificateRevocationImpact.associatedApps` | 顶层 serial **或** 任一签名 target 的 serial 命中 |
| 下方「本机已安装 App」清单 | `CertificateRevocationImpact.affectedApps` | **只看顶层 serial**，且要求 `state == .installed` |

于是会出现自相矛盾：标签说「本机已安装 App 在用」，清单却说「暂无」。
Seal 尤其容易中招 —— `AppRecord.belongsInInstalledList` 对 `isSeal` **恒为真**，
而它的 `state` 在部分路径下不是 `.installed`，被 `affectedApps` 的 `state` 前置条件挡掉。

另外补充一个**次要风险点**（不是本次改动引入的，但会影响关联）：
Seal 记录的 `certificateSerialNumber` 只来自「运行包主程序的真实 CMS 签名者」
（`SelfAppRegistrar` 的 `installedIdentity?.mainTarget?.signerSerialNumber`，
失败时**静默保留旧值**）。如果某次身份读取失败，记录里的序列号就会停在旧证书上，
于是任何按序列号的关联都查不到它。这条链路是刻意的安全设计（绝不拿描述文件授权列表
反推签名者，见 DEBUG_LOG 2026-09-16 血教训），**不应放宽**。

### 已实施
- 新增 `CertificateRevocationImpact.installedAppsAssociated(serialNumber:apps:)`
  = `associatedApps(...)` + `filter(\.belongsInInstalledList)`，即「与行标签同源，但只留本机已安装」。
- `SigningCertificateSettingsView.installedAppsSection` 改用它。
- **`affectedApps` 语义一行未动**：它仍用于撤销影响评估（口径更严，只算真正会失效的已装应用），
  两者不可合并。`verify-release-safety.py` 里新增一条守卫断言这条分界。
- 新增 4 条单测（`CertificateRevocationImpactTests`）：target-only 记录命中、
  Seal 即使 `state != .installed` 也必须出现、未安装的普通 App 不进清单、`affectedApps` 口径不变。

### 合理性评估
这是**必须修**的不一致，而不是「显示风格」问题：用户看证书页就是为了判断
「撤了这张证书会死哪些 App」，两处给出不同答案等于让这个页面失去可信度。

### 真机确认方法（问题 4 与 5 共用）
1. 打开「我的 → 签名证书 → 本机在用证书」：记下序列号（现为完整 40 位）。
2. 打开「应用 → Seal → 应用详情」：`证书序列号` 应与之**逐字符相同**。
3. 若不一致 → 说明 Seal 记录的签名者身份没能回补（身份读取失败保留了旧值），
   需查 `Documents/Seal-log.txt` 中的身份读取结果。

---

## 问题 5 · 是否真的用了「7 天的最新的时间」

### 结论：**代码层面是真的，而且是三重强校验；但用户此前无法自证**。

真实 7 天窗口由三处强制（`Seal/Infrastructure/Signing/ApplePortalSigningService.swift` +
`Seal/Core/Signing/ProvisioningProfileBinding.swift`）：

1. `minimumFreshProfileLifetime = 7*24*3600 - 10min`（10 分钟时钟容差）。
2. **取到即校验**：`validateFreshProfile` → `validateFreshness` 要求
   - `creationDate >= requestedAfter` —— 证明这份 profile 是**本轮请求之后**生成的，
     旧文件直接判 `SEAL-PROFILE-315a`；
   - `expirationDate - now >= 7天 - 容差`，否则 `SEAL-PROFILE-316`。
3. **不达标立刻在同一 Apple 会话重取一次**；仍不达标就失败，不会把短命 profile 装上去。
4. **签完再验一遍成品包**：`validateEmbeddedProfiles` 对主程序 + 每个扩展的
   `embedded.mobileprovision` 再跑一次同一套 freshness 校验（`SEAL-PROFILE-315/315a/316/318`）。

所以「假数据 / 沿用旧 profile」这条路在代码上是被堵死的。
`Seal` 自身记录的到期时间也不是乐观值：自替换对账（`SelfAppRegistrar`）以**运行包内真实
profile** 为准回写，续签失败会回滚到旧包的真实值（R07）。

### 已实施（把「可自证」补上）
`应用详情` 页现在暴露三个字段，可直接核对续签是否真的换了一份新 profile：

- `描述文件` → 该应用实际使用的 profile **UUID**（独占一行、灰色等宽、可选中）
- `描述文件创建时间` → 续签后应等于**刚刚**（同版本续签只有 UUID/创建时间/有效期会变）
- `描述文件有效期至` → 应为「今天 + 7 天」

判断标准很简单：**UUID 变了、创建时间是刚刚、有效期是 +7 天** → 本轮续签真实生效。

### 合理性评估
「查是不是假数据」这个担心合理，但排查方式建议改一下：
不要只看剩余天数（`expiryDate` 是派生值，可能来自乐观写入），
要看 **profile UUID + 创建时间** —— 这两个是「本轮 Apple 确实重新签发了」的不可伪造证据。

### 更好的做法（后续可选）
在签名完成日志里显式打一行 `profile UUID / creationDate / expirationDate`（脱敏），
导出 `Seal-log.txt` 就能一次性确认，不必进 UI。

---

## 问题 6 · 续签完回主屏像闪退

### 根因
`SelfInstallAutoBackground.backgroundAfterSealUpload()` 旧实现：

```swift
try? await Task.sleep(2s)              // ① 界面静止 2 秒，没有任何反馈
let app = UIApplication.shared
guard app.applicationState == .active else { return }
let selector = NSSelectorFromString("suspend")
guard app.responds(to: selector) else { return }   // ② 不响应就静默什么都不做
_ = app.perform(selector)
```

三个问题叠加：
1. 静止 2 秒 → 界面瞬间消失，缺少可感知的「要退出了」信号，观感等同闪退。
2. **`suspend` 是私有 selector**；一旦某系统版本 `responds(to:)` 返回 false，
   函数**静默返回什么都不做**，最后由 installd 直接杀进程 —— 这才是真正的「闪退」路径。
3. `suspend` 与安装 RPC 的时序耦合（`MinimuxerInstallChannel` 注释明确写过：
   提前 suspend 会冻结进程内的 installation_proxy 连接）。所以**不能靠提前 suspend 来「加速」**。

### 已实施
- `SigningProgressView` 新增 `@State isReturningHome`：进入 `.installing`（Seal）时先
  `withAnimation(.easeInOut(0.45))` 把状态置位 —— 文案切成「正在退回主屏幕」、
  提示透明度做一次淡出，**先把这一帧渲染出来**，再触发系统转场。
- `SelfInstallAutoBackground` 重写为 `returnToHomeAfterSealUpload()`：
  1. 可感知停顿从 2s 收到 **1.2s**（命名常量 `transitionBeatNanoseconds`，便于调）；
  2. `triggerHomeTransition` 双路径：先 `app.perform("suspend")`，不响应再走
     经典写法 `UIControl().sendAction(selector, to: app, for: nil)`；
  3. 两条都不通才 `exit(0)` 兜底（系统同样会播放 App 退场动画），
     保证进程一定结束、iOS 才能完成替换。
- 只做「切后台 / 退出」，**不碰任何签名、证书、自替换事务状态**：安装结果仍由
  重新打开的新进程 `SelfReplacementCoordinator` 对账确认。

### 合理性评估
「要有过渡」合理。但请注意**这里能做的上限**：
真正「丝滑退回主屏」的动画是**系统给的**（`suspend` 等价于按 Home），App 无法自己画；
App 能做的只有「先把意图说清楚，再触发系统转场」，以及「转场不可用时别静默摆烂」。
本次改动正好落在这两点上。

### 风险与必须真机验证的点
- `exit(0)` 只在 suspend 完全不可用时触发。它**不会**比 suspend 更早打断安装
  （suspend 同样会冻结 installation_proxy 连接），但**必须在真机上确认**：
  ①正常路径（suspend 可用）下替换完成、重开已是最新；
  ②强制走 `exit(0)` 兜底时不会留下旧 profile（若发现，应改为「等安装 RPC 返回再退后台」，
  代价是用户多等几秒，换来的是 `MinimuxerInstallChannel` 注释里那条会话不变量）。
- 1.2s 这个停顿是启发式值；若真机上出现「暂存未落盘就被切走」，应回调到 1.5–2s。

---

## 问题 7 · 描述文件「可用」→ 该应用使用的 UUID（独占一行、灰色）

### 根因（呈现）
`描述文件` 行原来显示的是**状态枚举文案**（`ProfileDisplayStatus.title`，`.available` → 「可用」），
只回答「有没有问题」，不回答「到底是哪一份 profile」——
而后者才是排查续签是否生效时真正要看的东西（与问题 5 同源）。

### 已实施
- 新增 `AppSigningPresentationHelpers.profileUUIDText(for:)`：优先顶层
  `provisioningProfileUUID`（安装确认后回写的真实 profile），回退到签名 target（主 target 优先），
  都没有则「未记录」。
- `AppDetailView` 与 `InstalledAppActionSheet` 的 `描述文件` 行：值改为
  **profile UUID 独占一行、灰色等宽、可长按选中**。
- **异常状态标签保留**：仅当状态不是 `.available`（临期 / 已过期 / 不匹配 / 待校验 / 未记录）
  时，才在标题右侧显示状态标签。
  理由：`.mismatch`（profile 与 Team/BundleID/证书/设备对不上）是**安全信号**，
  按字面把这一格完全删掉会让用户失去「这包其实装错了」的提示；
  而 `.available` 这一档的信息由下一行「描述文件有效期至」的颜色（绿/黄/红）承载，不丢信息。

### 合理性评估
「用 UUID 取代『可用』」合理且信息量更大；但**完全删掉状态**不合理，
所以这里做了折中（只留异常态）。如果你确认不需要异常态提示，
把 `if status != .available` 去掉即可一行还原。

---

## 改动文件清单

| 文件 | 改动 |
|------|------|
| `Seal/Features/Apps/AppPresentation.swift` | `certificateSerialText`（替代 `certificateName`）、`sealReturningHomeTip`（替代 `sealReplacementTip`）、`profileUUIDText`、`profileCreationDate` |
| `Seal/Features/Apps/SigningProgressView.swift` | 提示文案统一 + 安装阶段切换；`isReturningHome` 转场；`runtimeSerialRow`；`SelfInstallAutoBackground` 重写 |
| `Seal/Features/Apps/AppDetailView.swift` | 行标题改「证书序列号」；`serialDetailRow` 值独占一行；`profileDetailRow`（UUID）；新增「描述文件创建时间」 |
| `Seal/Features/Apps/AppSigningSheet.swift` | 行标题改「证书序列号」；`summarySerialRow` |
| `Seal/Features/Apps/InstalledAppActionSheet.swift` | `metadataValueRow`（序列号 / UUID 独占一行）；去掉「可用」占位 |
| `Seal/Features/Apps/AppsViewModel.swift` | 新增非阻塞 `beginSigningChannel()`；`runSigning` 不再阻塞在连设备 |
| `Seal/Core/Signing/CertificateRevocationImpact.swift` | 新增 `installedAppsAssociated`（`affectedApps` 未动） |
| `Seal/Features/Settings/SigningCertificateSettingsView.swift` | 「本机已安装 App」清单改用 `installedAppsAssociated` |
| `Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift` | `start()` 单飞合并（`inFlightStart`） |
| `Seal/Core/Signing/SigningCoordinator.swift` | 安装前 await 通道失败时抛底层诊断错误（不再 `try?` 吞） |
| `SealTests/Settings/CertificateRevocationImpactTests.swift` | +4 条单测 |
| `Scripts/verify-release-safety.py` | 证书页守卫改为断言「清单与行标签同源」+ 新增 1 条变异 |

## 验证清单

**已在本机执行**
- `python Scripts/verify-release-safety.py` → `PASS`（Source 129 / Mutation 55）。

**必须在 macOS / 真机执行**
1. `bash Scripts/verify-signing-model.sh`（xcodegen + 单测 + rork-sign 测试 + 未签名 IPA 校验）。
2. 云构建三 job：`build-package` / `swift-regression` / `rork-sign-tests`。
3. 真机回归：
   - 单签 + 续签（普通 App）：点下去后**不再**长时间停在「正在连接设备」；
     连设备失败时给出的是可操作的诊断文案，而不是笼统的安装失败。
   - Seal 自续签：进度到安装阶段 → 文案切「正在退回主屏幕」→ 平滑回主屏 →
     重开确认已是新版 → 设置页自动确认安装结果。
   - 证书页：Seal 出现在「本机已安装 App」清单里，序列号与详情页逐字符一致。
   - 详情页：`描述文件` UUID 与 `描述文件创建时间` 在续签后**都变了**，有效期 = +7 天。
