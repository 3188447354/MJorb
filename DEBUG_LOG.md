# DEBUG_LOG

> 复盘记录：现象 → 根因 → 修复 → 涉及文件 → 验证状态。新条目追加到「历史记录」顶部（最新在前）。
> 动手前先查阅下方「常犯坑位」，避免同类问题重复发生。

---

## 常犯坑位

- **证书序列号跨来源比对必须归一化**（strip leading zeros），否则会用不同表示误判「证书被轮换/不在授权列表」。
- **进度条卡 % 是阶段切换时机问题，不是进度值本身**。排查进度显示别盯着百分比，要看阶段切换回调。
- **`rg` 查询带再加工时，行号输出用 `-n`，别拿 `-r` 当行号**。
- **证书轮换 / 证书自动清理两条撤销路径都要各自守住「无法确认 Seal 真实签名证书就禁止撤销」**，缺一条就会误删 Seal 自己的命根子证书。
- **iLoader 等第三方签名工具产出非标准签名结构/描述文件**，Seal 的 `AppBundleSigningIdentityReader` 可能读不出真实 CMS 签名者，会连锁触发 SEAL-CERT-232 / SEAL-SELF-105，只能电脑覆盖安装兜底。**允许放宽的只有「CodeDirectory 全量哈希校验」（第三方改结构导致哈希对不上属正常），身份识别仍必须落在「一致 signer serial」+ `signerNotAuthorizedByProfile`（serial 须在描述文件授权证书内）双校验上；任何「连 signer serial 都读不出仍继续签名」的弱化都是明令禁止的**——那会直接导致误删 Seal 自己命根子证书。
- **改动核心语义（签名/证书/续签）时，老的同名单测往往断言的就是正要被替代的行为**。改实现后云构建的 `swift-regression` 就会在这些测试上红（exit 65），而 `build-package` / `rork-sign-tests` 仍绿。动手前先 grep 相关 `SealTests/**/*Tests.swift` 核对断言，并与实现改动同步更新到新设计，避免「改实现 → 推一次 → 只有这里红 → 再修测试推一次」的双倍等待。
- **`verify-release-safety.py` 的守卫会按字符串断言 UI 结构**。改动证书页/证书展示相关代码时，先跑一遍守卫（Windows 上也能跑），它会直接点名「哪条断言 + 哪个变异锚点」失效；改动是有意为之就同步更新守卫（连同变异锚点），**不要为了过守卫把实现写回去**。
- **同一实体的两处 UI 展示必须同源**。同一张证书的「关联了哪些 App」曾出现行标签用 `associatedApps`（含扩展 target）、下方清单用 `affectedApps`（只看顶层 serial + `state == .installed`）两套判定，结果自相矛盾（标签说在用、清单说暂无），Seal 自身因 `belongsInInstalledList` 恒为真且 `state` 不一定是 `.installed` 尤其容易被漏掉。**展示口径要复用同一个函数**；撤销影响评估仍走更严的 `affectedApps`，两者不可合并。
- **私有 selector + `guard responds(to:) else { return }` = 静默 no-op**。Seal 自续签的「回主屏」原来只有一条 `perform("suspend")`，不响应时什么都不做，最后由 installd 杀进程 —— 用户观感就是「闪退」。凡是靠私有 API 实现的可感知行为，都必须有兜底路径（此处是 `UIControl().sendAction(_:to:for:)` + `exit(0)`），不能静默返回。
- **「卡很久」的排查方向是「该并行的被串行等了」，不是「超时太长」**。签名/续签曾卡在「正在连接设备」很久：`SigningCoordinator` 里已经做了隧道与签名并行，但 `AppsViewModel.runSigning` 在更早的位置 `await refreshSigningChannel()` 把整段诊断又同步等了一遍，并行化对首个调用完全失效。**改并行化时要顺着调用链往上游找还有没有第二次同步等待**；并发启动同一通道还要在通道层做单飞合并，否则重复诊断、耗时翻倍。
- **批量入口解阻塞的前置条件是「下游有熔断」**。`startBatchRefresh` 的前置 `await refreshSigningChannel()` 看着像冗余，其实是保护：`MinimuxerInstallChannel.startOnce` 失败时**不写缓存**，去掉等待后通道不可用会让 N 个 App 各跑一遍 75s 诊断（N×75s）。**要解阻塞必须先在通道层加失败熔断**（失败后 60 秒窗口内直接抛同一错误），并且熔断只能挡「同一轮批量内部」的连续调用 —— 用户发起的会话（`runSigning` / `startBatchRefresh` / `refreshSigningChannel`）都要显式 `clearFailureCooldown()`，否则用户修好 VPN 再点也被秒拒，看起来像 Seal 坏了。
- **只在 extension 里给方法默认实现 = `any Protocol` 静态派发到空实现**。`clearFailureCooldown()` 若只写在 extension，`any InstallChannel` 会调用默认空实现，具体实现的覆写永远不执行，表现是「用户手动重试一直被拒」而守卫全绿。**凡是需要动态派发的行为都必须声明为 protocol requirement**（本仓 `install(onProgress:)` 已踩过一次，现已加守卫断言锁住）。
- **Apple 免费账号的 `1100 session expired` 多数是「限流被掐断」，不是真过期**。抖音（主 App + 8 扩展 = 9 个 bundle ID）在 App ID 阶段连发 9 次 `addAppID` + 9 次 `updateFeatures`、再连发 9 次描述文件申请，二十余次密集请求会触发 Apple 掐断会话。**判据：报错前 1–3 秒若有「证书决策」成功，说明 session 服务端仍有效**（同一账号几分钟前刚成功签过别的 App 也是同一证据）。此时引导用户「重新验证 Apple ID」是死循环 —— 重新登录后密集请求再次触发限流。对策是请求节流 + 对 1100 退避重试，且 **App ID 阶段的 1100 文案必须与 account 阶段分开**（前者给「稍后重试」，后者才给「去重新验证」）。
- **错误分类禁用子串匹配**。`diagnostic.contains("1100")` 会把形如 `com.example.app1100` 的 Bundle ID 报错误判成「会话过期」，把「Bundle ID 不可用」错报成「登录过期」。只认错误码 + 官方英文文案。
- **统计字段的文案要跟字段语义对齐**。`usedBundleIDCount` 是「已注册存活数量」，却被渲染成「N 个可用 App ID」——日志里 `10 个可用 App ID` 的真实含义是**已用满 10 个**。这直接导致用户「id 有足够的名额」的误判，把排查方向带偏。同一字段在别处（`已签名 n / 10`）写法是对的，**两处口径不一致时以字段定义为准，并统一**。

---

## 历史记录

### 2026-09-16 · 抖音（8 扩展）签名必失败：Apple 限流被误报成「登录过期」；批量续签解阻塞

- **现象**：签抖音（主 App + 8 扩展 = 9 个 bundle ID）时，**无论怎样都会在「正在验证 Apple ID」报错失效**，反复重新验证 Apple ID 也无效；签其他 App（Kazumi 1 个 bundle ID、Sollin Player 2 个）完全正常。用户认为「id 名额足够」。
- **根因**：`ApplePortalSigningService.prepareProfile` 对 9 个 bundle ID 串行执行 Phase 1（`addAppID` + `updateFeatures` ×9）与 Phase 2（描述文件申请 ×9，每次含 delete + 重取），**短时间二十余次密集请求触发 Apple 对免费账号的限流**，返回 `1100 Your session has expired`。
  - **决定性证据**：每次 `AUTH-107` 报错前 1–3 秒都有一条「证书决策」成功日志（21:15:40→21:15:41、21:18:14→21:18:16、21:31:43→21:31:46）。证书能申请成功说明 session 在服务端仍然有效。
  - **旁证**：同一账号 `mar***7***@gmail.com` 在 21:07:38 刚成功签完 Kazumi，6 分钟后签抖音即报「登录过期」。
  - 代码里原本已有注释提到「1100 在 App ID 创建阶段也会出现（如抖音签名时）」，但只做了错误分类，没有处理限流本身 —— 分类正确了，问题还在，用户被反复引导去重新验证。
- **修复**：
  1. 新增全局 `AppleRequestThrottle`（相邻请求 ≥ 0.4 秒），挂在 **`withAppleTimeout` 开头** —— 它是所有 Apple 请求的唯一入口，一处覆盖全部调用点。节流只在间隔不足时等待，对 500ms 轮询与单 App 签名零影响。
  2. 新增 `withSessionRecovery`：对 `addAppID` / `fetchProvisioningProfile` 命中 1100 时退避重试（1.5s / 4s / 8s），耗尽才抛。**只重试 1100**，网络超时、Bundle ID 冲突（9400）、名额上限（3013）仍立即失败。
  3. **App ID 阶段的 1100 文案与 account 阶段拆开**：前者改为「Apple 暂时拒绝了请求 / 请先等几分钟再重试」，后者保留「去重新验证」。这是打断死循环的关键。
  4. 消除 `diagnostic.contains("1100")` 子串误判，统一走 `isSessionExpiredError`（只认错误码 + 官方文案）。
- **附带修掉**：`SettingsViewModel` 把 `usedBundleIDCount`（已注册存活数）渲染成「N 个可用 App ID」，语义完全反了 —— 日志里「10 个可用」实为**已用满 10 个**，直接造成用户「名额足够」的误判。改为「已注册 N / 10」，与 `CertificatesRootView` 的「已签名 n / 10」统一。
- **同轮做的优化**：`startBatchRefresh` 去掉前置 `await refreshSigningChannel()`（「点续签后卡很久」的第二个入口）。解阻塞的前提是**先在通道层加失败熔断**（60 秒窗口）—— 否则通道不可用会退化成 N×75s 诊断。熔断配合既有 `inFlightStart` 单飞，整轮批量只付一次诊断代价。用户发起的会话显式 `clearFailureCooldown()`，不会被熔断误挡。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、`Seal/Core/Installation/InstallChannel.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`SealTests/Signing/AppleRequestThrottleTests.swift`（新增）、`Scripts/verify-release-safety.py`。
- **待核对的结构性约束**：免费账号 App ID 名额是「7 天窗口内最多 10 个」，**一轮抖音签名就吃掉 9 个**（主 + 8 扩展），7 天后过期又要重注册。这是 Apple 侧限制，代码无解 —— 建议抖音用付费账号签，或接受丢弃部分扩展。本次失败全部是 `AUTH-107`，没有一次 `SEAL-APPID-304`，所以名额不是本次的直接原因，但值得用户核对。
- **验证状态**：静态守卫 PASS（139 源码断言 + 59 变异）。**待 macOS 编译 + 真机回归**（本机无 Swift 工具链）。真机重点：日志里是否出现「Apple 会话疑似被限流，退避 N 秒后重试…」；退避后是否成功；批量续签是否不再长停「正在连接设备」。

### 2026-09-16 · 自续签 7 问：连设备卡顿（真 bug）、证书/描述文件展示统一、关联判定同源、回主屏转场

- **现象（用户报的 7 条）**：
  1. 签名/续签卡在「正在连接设备」很久。
  2. 「Apple ID 证书 · 序列号 xxx」要统一成「证书序列号 + 完整序列号」，且序列号要显示全面。
  3. Seal 自续签的蓝色文案要跟普通 App 一样。
  4. 续签后的证书没关联到 Seal 自己（「此证书已安装 App」里看不到 Seal）。
  5. 要确认用的是真实的 7 天新时间，而不是假数据（怕第二天掉签）。
  6. 续签完回主屏像闪退，要有过渡。
  7. 描述文件「可用」要换成「该应用使用的 UUID」独占一行灰色。
- **根因**：
  1. **真 bug**：`SigningCoordinator` 里「隧道与签名并行」已做过，但 `AppsViewModel.runSigning` 在调用协调器**之前** `await refreshSigningChannel()` → `installChannel.start()`，把整段隧道诊断（reset + 18s RSD 握手 + 36×500ms 轮询，硬超时 75s）又同步等了一遍，并行化对首个调用完全失效；`updateState/.progress(.waitingForChannel)` 又把 UI 钉在「正在连接设备」。
  2. 序列号在标题右侧单行渲染 + `.truncationMode(.middle)` + `.minimumScaleFactor(0.8)`，40 位十六进制必然被截断；「序列号 · 」前缀还白占位置。
  3. Seal 专属 `sealReplacementTip`（「请按 Home 键回到主屏幕」）是「自动回主屏」上线前的产物，现在说反了。
  4. **真 bug**：同一张证书的两处展示不同源 —— 行标签用 `associatedApps`（含扩展 target），下方清单用 `affectedApps`（只看顶层 serial + `state == .installed`），于是「标签说在用、清单说暂无」；Seal 的 `belongsInInstalledList` 恒为真但 `state` 不一定是 `.installed`，被前置条件挡掉。
  5. 代码侧已三重强校验真实 7 天（取到即校验 + 不达标同会话重取 + 成品包 embedded profile 再验），但 UI 不暴露 profile 身份，用户无法自证。
  6. `SelfInstallAutoBackground` 静止 2s 后只走一条 `perform("suspend")`，`responds(to:)` 为假时**静默什么都不做**，最后由 installd 杀进程 → 观感等同闪退。
  7. `描述文件` 行显示的是状态枚举文案（`.available` → 「可用」），只回答「有没有问题」，不回答「是哪一份 profile」。
- **修复**：
  1. 新增非阻塞 `AppsViewModel.beginSigningChannel()`（`runSigning` 改用它，不再 await）；`MinimuxerInstallChannel.start()` 增加单飞合并 `inFlightStart`，避免 ViewModel 与协调器并发重跑诊断；`SigningCoordinator` 安装前 await 通道时不再 `try?` 吞错，只在 `isReady()` 为假时抛底层 `SEAL-VPN-*`/`SEAL-PAIR-*`。
  2. `certificateName(serial:)` → `certificateSerialText(serial:)`（只返回完整序列号，去掉前缀）；行标题统一「证书序列号」；值独占一行、灰色等宽、可长按选中。四个入口（详情页 / 进度页 / 操作面板 / 签名表单）全部统一。
  3. 进行中一律 `keepSealOpenTip`；删除 `sealReplacementTip`，新增 `sealReturningHomeTip` 只在 Seal 进入 `.installing` 后显示。
  4. 新增 `CertificateRevocationImpact.installedAppsAssociated`（= `associatedApps` + `belongsInInstalledList`），证书页清单改用它；**`affectedApps` 语义未动**，撤销影响评估仍走它；守卫新增断言这条分界 + 4 条单测。
  5. 详情页新增 `描述文件` UUID 行与 `描述文件创建时间` 行：续签后 UUID 变、创建时间是刚刚、有效期 = +7 天，即可自证真实生效。
  6. `SigningProgressView` 新增 `isReturningHome`，进入 `.installing` 先 `withAnimation` 渲染「正在退回主屏幕」再触发系统转场；`SelfInstallAutoBackground.returnToHomeAfterSealUpload()` 双路径 suspend（`perform` → `UIControl().sendAction(_:to:for:)`）+ `exit(0)` 兜底；可感知停顿 2s → 1.2s。
  7. `描述文件` 行的值改为 profile UUID 独占一行灰色等宽可选中；仅当状态不是 `.available` 时保留状态标签（`.mismatch` 是安全信号，不能删）。
- **涉及文件**：`AppPresentation.swift`、`SigningProgressView.swift`、`AppDetailView.swift`、`AppSigningSheet.swift`、`InstalledAppActionSheet.swift`、`AppsViewModel.swift`、`CertificateRevocationImpact.swift`、`SigningCertificateSettingsView.swift`、`MinimuxerInstallChannel.swift`、`SigningCoordinator.swift`、`SealTests/Settings/CertificateRevocationImpactTests.swift`、`Scripts/verify-release-safety.py`。
- **验证状态**：`python Scripts/verify-release-safety.py` PASS（Source 129 / Mutation 55）。**待 macOS 编译 + 真机回归**，重点：①单签/续签不再长时间停在「正在连接设备」，且通道真失败时给可操作文案；②Seal 自续签进度→文案切「正在退回主屏幕」→平滑回主屏→重开是最新且设置页自动确认；③证书页 Seal 出现在「本机已安装 App」清单且序列号与详情页逐字符一致；④详情页 profile UUID 与创建时间在续签后都变、有效期 = +7 天。**风险点**：`exit(0)` 仅在 suspend 完全不可用时触发，需确认不会留下旧 profile（若出现，改为「等安装 RPC 返回再退后台」）；1.2s 停顿若导致暂存未落盘被切走，回调到 1.5–2s。
- **详见**：`docs/qa/2026-09-16-renewal-ux-and-cert-issues.md`（含逐条「要求本身合不合理 / 有没有更好的做法」评估）。

### 2026-09-16 · 批量续签 Seal 自动回主页：补发 .installing 信号（含去冗余开关）；签名进度页序列号与详情页同步

- **现象**：
  1. 批量续签里 Seal 到安装阶段不会像单签那样自动回主页。
  2. `SigningProgressView` 的「Apple ID 证书」行只显示「可用」，看不到具体序列号，与应用详情页展示不一致。
- **根因**：
  1. 批量续签的 `progress` 回调（`RenewalCoordinator` → `.appProgress(…, stage:)`）只透传 `SigningStage`，接不到单签用的 1.01 上传哨兵；而 Seal 走 `submitPrepared` 只发 `.pushing`，不发 `.installing` → 批量里 Seal 永无 `.installing`，`consumeBatchEvent` 里 `app.isSeal && stage == .installing` 分支永远不命中。
  2. 两处证书展示各写各的：详情页 `AppDetailView.certificateName` 输出「序列号 · .fullSerial」，签名进度页 `SigningProgressView.certificateDisplayName` 只回「可用」。
- **修复**：
  1. `installSignedIPA` 的 Seal 分支在 `submitPrepared` 上传完成（>1.0）时补发一次 `progress(.installing)`（`SigningCoordinator.swift:1233`），批量经 `.appProgress` 命中 `consumeBatchEvent` 触发 `SelfInstallAutoBackground`。**去冗余**：新增显式开关 `broadcastInstallingForSelfReplacement`（默认 false），仅 `RenewalCoordinator.swift:232` 批量续签传 true；单签续签 Seal 仍靠 `onInstallProgress` 的 1.01 → `SigningProgressView.onChange` 触发，不在此补发，消除对同一事件的双重触发。
  2. `SigningProgressView.certificateDisplayName` 改为复用 `AppSigningPresentationHelpers.certificateName(serial:)`，用 `session.selectedCertificateSerialNumber ?? session.account.certificateSerialNumber` 生成「序列号 · .fullSerial」，与详情页同源同 helper 完全同步；证书未确定仍显示「未准备」。
- **涉及文件**：`SigningCoordinator.swift`、`RenewalCoordinator.swift`、`SigningProgressView.swift`。
- **验证状态**：待 Xcode 编译 + 真机回归（重点：批量续签 Seal 自动回主页、单签不重复回主页；签名进度页显示真实序列号与详情页一致）。

### 2026-09-16 · 自续签 93%：自动回主页 + 安装转圈动效；连接设备并行化不再阻塞签名

- **现象**：签名/续签安装到 93% 后 UI 静止像卡死，要人手按 Home 才让 iOS 完成替换；签名/续签的「连接设备」环节单次也明显卡顿（哪怕只签单个 App）。
- **根因**：
  1. **93% 卡死感**：Seal 自续签=覆盖安装运行中的自己，iOS 只有等旧进程退后台才用新版替换；但进度 UI 把 `.installing` 定成静止 93%，没有任何动效反馈。
  2. **连接设备卡顿**：`signAndInstall` 在签名**前**同步 `installChannel.start()`，整段隧道诊断（reset + 18s RSD 握手 + 36×500ms 轮询）阻塞签名；签名所需的 UDID 其实配对缓存就有，根本不必等隧道就绪。
- **修复**：
  1. **自动回主页**：进入 `.installing`（上传完成哨兵 1.01 触发 `.pushing→.installing`）后，`SigningProgressView.onChange` 对 Seal 自续签自动 `suspend` 切后台（`NSSelectorFromString("suspend")`+`responds` 守卫，不可用则静默降级），installd 在后台任务保护下完成替换，结果由重开的新进程对账——不再手按 Home。
  2. **转圈动效**：Seal 自续签 `.installing` 阶段进度环改为持续转圈的「替换中」动效（`selfReplacementInstallingRing`），不再静止 93%。
  3. **连接并行化**：`signAndInstall` 隧道改 `Task { try await installChannel.start() }` 后台平行启动；签名 UDID 从配对缓存 `storedDeviceIdentifier()` 快速读取（描述文件只认 UDID 与隧道无关），无人工痕迹的首次未配对场景仍等一次隧道。安装唯一漏斗 `installSignedIPA` 开头 ensure 通道就绪（`!isReady() → start()`，命中 900s 缓存近乎零等待），覆盖缓存/新签/续签三条路径，避免 `install()` 因通道冷而直接抛 channelNotReady。
- **涉及文件**：`Seal/Features/Apps/SigningProgressView.swift`（转圈动效 + 自动回主页）；`Seal/Core/Signing/SigningCoordinator.swift`（连接并行化 + 安装漏斗 ensure 通道）。
- **验证状态**：待 Xcode 编译 + 回归样本真机验证（重点：①Seal 自续签到 93% 转圈、数秒后自动回主屏完成替换、重开已是最新并自动确认；②单/批量签名「连接设备」不再停顿、签名完成即装；③普通 App 签名安装互不影响、不误触发自动回主页）。`suspend` 为私有 API，若系统不可用必须静默回退到旧「按 Home」路径，不得报错中断。
- **已知边界（已补齐）**：自动回主页原来只在**单 App 续签**的 `SigningProgressView` 触发；批量续签 Seal 走 `BatchRefreshView`，其 `progress` 回调只透传 `SigningStage`、接不到 1.01 上传哨兵，导致批量里 Seal 永远收不到 `.installing`。补齐方式：`installSignedIPA` 的 Seal 分支在 `submitPrepared` 上传完成（>1.0）时补发一次 `progress(.installing)`，`AppsViewModel.consumeBatchEvent(.appProgress)` 对 `app.isSeal && stage == .installing` 触发 `SelfInstallAutoBackground`（已改为 internal 供两处复用）。**注意**：Seal 自续签必然替换运行中的自己、进程会被新包终止，其后排队的续签项会一并中断（与手按 Home 相同），这是 Seal 自更新的固有语义。

### 2026-09-16 · 自续签安装卡 93%、连接设备卡顿、检查安装结果要手动——三处连点优化

- **现象**：用爱思签的 Seal（Bundle ID 已带 `.CT8QZ7352B`）能正常自续签，但安装停在 93%；只有手动退回主屏幕才真正完成替换。签名/续签都在「正在连接设备」环节卡顿。证书页的「检查安装结果」要人手点，不会自动确认。
- **根因**：
  1. **93% 卡顿**：Seal 自续签=覆盖安装正在运行的自己，iOS 只有等旧进程退到后台才用新版完成替换。MinimuxerInstallChannel 为不让 installation_proxy 连接被冻结而刻意不切后台，于是 `.installing` 阶段被定死在 93% 干等，直到手按 Home 触发 swap 才落盘。进度 UI 的「是否保持前台」提示在这个场景下正好说反了。
  2. **连接设备卡顿**：`MinimuxerInstallChannel.start()` 的设备标识缓存窗口只有 60s。批量续签在两次 start 之间每个 App 都要签名、申请描述文件，一超过 60s 缓存过期就整体重跑诊断（reset + 18s RSD 握手 + 36×500ms 轮询），于是每个 App 都要在「连接设备」重卡一次。
  3. **检查安装结果要手动**：自替换 `reconcile(…)` 在「当前进程 == 提交进程」时固定返回 `.awaitNextLaunch`，必须由「重新打开的新进程」在启动维护里对账结算；设置页只支持点按钮重读本地状态，没有等待确认态下自动刷新，等新进程结算完成后 UI 不会自己切到已完成。
- **修复**：
  1. 进度文案区分 Seal 自续签与普通续签：Seal 显示「进度走完后按 Home 回到主屏幕，iOS 会用新版替换；替换完再重新打开」（新增 `AppSigningPresentationHelpers.sealReplacementTip`），不再误导「保持前台干等」；`awaitingReplacementConfirmation` 的 detail 同步改为「回主屏幕让 iOS 完成替换，再重新打开，本页会自动确认」。
  2. `MinimuxerInstallChannel` 缓存窗口 `60s → 900s`（整场签名/续签会话），命中仍要求 `isReady()` 为真，设备真断了不会用到陈腐缓存。
  3. 设置页等待确认态 `.task(id: state)` 自动每 2s 重读 `refreshSelfManagementState`，新进程结算/关闭事务后本页自动切到已完成，保留「检查安装结果」按钮作兜底。
- **涉及文件**：`Seal/Features/Apps/AppPresentation.swift`、`SigningProgressView.swift`；`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`；`Seal/Features/Settings/SettingsViewModel.swift`、`SigningCertificateSettingsView.swift`。
- **验证状态**：待 Xcode 编译 + 回归样本真机验证（重点：Seal 自续签 93%→退后台→重新打开→设置页自动确认；批量续签连设备不再逐 App 卡顿；「检查安装结果」无需手动）。注意：本改动未触碰自替换对账/结算核心语义，`reconcileAtLaunch`/`settle` 仍由启动维护的 `SelfAppRegistrar` 负责。

### 2026-09-16 · 签名模型改动后旧单测断言被替代行为，导致 CI swift-regression 红

- **现象**：推送签名三改动（身份识别放宽 / 单槽位证书接管 / Bundle ID 团队后缀）后，云构建 `swift-regression` 在 12m27s 失败（exit 65），而 `build-package` / `rork-sign-tests` 均绿。
- **根因**：`BundleIDMapperTests.requestedMainBundleIdentifierWins` 断言「requested 原样胜出」（旧行为）；`CertificateTakeoverPolicyTests.singleRemoteCertificateWithFreeSlotCreatesLocal` 断言「两槽位下 1 张远程证书仍视为有空槽→createLocal」（旧两槽位语义）。两处都被本次故意改动的核心语义取代，单测没同步，实现行为变了、测试仍验旧行为。
- **修复**：单测对齐新设计——① requested 不再原样胜出，改为「未带当前 team 后缀则换算成 recommended（自动补 `.seal.teamID`）、已带则原样复用、大小写不敏感」；② 证书接管改为单槽位语义，「空槽（无远程证书）→ createLocal」，删除旧「单张远程证书当空槽」用例（其场景已由 `fullSlotsWithOnlySignerBlocks` 覆盖）。
- **涉及文件**：`SealTests/Signing/BundleIDMapperTests.swift`、`SealTests/Signing/CertificateTakeoverPolicyTests.swift`。
- **验证状态**：提交 `c37b378` 推送后重跑，run 68 三 job 全绿（build-package 3m25s / swift-regression 13m49s / rork-sign-tests 2m49s）。IPA `Seal_1.1.16.ipa`（sha256 `1c824466…`）已落盘 `Desktop/Seal_IPA/` 并二次校验通过。

### 2026-09-16 · 自续签身份源改为 Keychain/描述文件推断——评估后回退（守卫拦截）

- **提议**：问题2 想对齐 SideStore，让自续签在 Mach-O 读不出真实 signer（第三方工具签的非标准结构）时，用「描述文件授权证书 ∩ 本机 keychain 私钥证书，恰好 1 张」兜底确认 Seal 签名者，从而不再卡 SEAL-CERT-232 / SEAL-SELF-105。
- **回退原因**：实现后 `Scripts/verify-release-safety.py` 立即 FAIL 两条 Seal 自保护断言——本库硬性纪律是**绝不用描述文件授权列表推断 Seal 签名者**（2026-09-15 真机变砖血教训：授权列表含「并未实际签名」的证书，推断会保护错证书）。细想确有致命场景：Seal 由第三方工具签名时，profile 授权可能同现「本机 keychain 有私钥的旧证书」与「第三方签名证书」，交集恰好 1 张会保护错旧证书，放行撤销真正在用的第三方证书 → Seal 变砖。**守卫拦得对**。
- **处置**：回退 ApplePortalSigningService（`resolveSigningIdentity`）、SigningCoordinator 一键全撤、自动盘活清理三处兜底改动，恢复「只信 `installedIdentity`（真实 CMS 签名者），读不出即停止/SEAL-CERT-230/`.unavailable`」的既有安全模型；删除临时 helper。守卫恢复 PASS（128 + 54）。
- **结论**：第三方工具签的 Seal 自续签，仍按要求走「电脑原签名工具覆盖安装」这一既有安全兜底（SEAL-CERT-232 恢复文案），不因本次问题2 放宽。若真要做 Keychain 身份源，需重新设计并过安全评审（如电脑覆盖前把签名身份正确留存进 keychain，而不是设备端拿 profile 授权列表推断）。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`Seal/Core/Signing/SigningCoordinator.swift`（均已回退至基线）。
- **验证状态**：`verify-release-safety.py` PASS。改动未遗留，无编译期新符号。

### 2026-09-16 · Bundle ID 未带团队后缀导致跨设备互相占用

- **现象**：同一个（原始）Bundle ID 只要被某台设备/账号注册过，其他设备就无法再注册使用，报 `bundleIdentifierUnavailable`。
- **根因**：`BundleIDMapper.mainBundleID` 在 `requested` 非空时**直接原样返回**，不附加 `.seal.{teamID}` 后缀。UI 默认推荐值虽带后缀，但当用户手动输入、或沿用旧的 `preferredBundleIdentifier`（历史数据不带后缀）时，最终签名/注册的 Bundle ID 就没有「团队隔离后缀」。不同 Apple ID（不同 team）的设备就会用同一个字符串 bundle ID 去注册，先注册的占用后注册的。Apple 的 App ID 在团队维度隔离，靠后缀把不同账号签成不同字符串才能天然避免冲突。
- **修复**：`BundleIDMapper.mainBundleID` 对 `requested` 统一换算——已带 `.seal.{当前teamID}` 后缀（续签复用已安装 / UI 默认推荐）则原样保留；否则用 `BundleIDPolicy.recommendedBundleIdentifier(for:teamID:)` 统一附加当前团队后缀（会剥离多余 `.seal` 中间缀，避免 `xx.seal.seal.team`）。与上游 AltStore/SideStore「原始+teamID」策略对齐。
- **涉及文件**：`Seal/Core/Signing/BundleIDMapper.swift`。
- **验证状态**：待 Xcode 编译 + 回归样本（微信 / 黄豆短剧 / LCSign / lanmanga）真机验证，重点核对首次签名、手动改 Bundle ID、同 Apple ID 多设备三种路径最终签名 ID 均带当前 team 后缀。

### 2026-09-16 · 合法第三方签名被误判为 inconsistentArchitectures

- **现象**：Sideloadly 的 bundle mangle / 爱思非标准结构产生的合法签名，`AppBundleSigningIdentityReader` 因 CodeDirectory 全量哈希校验失败而判 `inconsistentArchitectures`，Seal 读不出身份，连锁触发 SEAL-CERT-232 / SEAL-SELF-105，无法自续签。
- **根因**：`inspectWithRorkSign` 把「CMS 密码学校验 + CodeDirectory 哈希校验」作为识别身份的双重硬条件；第三方工具持有合法证书 CMS 签名，但修改了二进制结构导致代码目录哈希对不上，被误判为无法识别。
- **修复**：**仅放宽 CodeDirectory 全量哈希校验**——改为以「能读出一致签名证书 serial」为识别身份的依据（多架构 serial 一致才通过），CMS/哈希校验状态如实记入 evidence 供诊断；`readTarget` 的 `signerNotAuthorizedByProfile`（signer serial 必须落在描述文件授权证书内）校验保持不变，防误撤销自身证书的原始目的仍未放松。
- **涉及文件**：`Seal/Infrastructure/Renewal/AppBundleSigningIdentityReader.swift`。
- **验证状态**：待 Xcode 编译 + 回归样本真机验证。

### 2026-09-16 · iloader 非标准签名导致 Seal 无法自续签

- **现象**：设备上续签 Seal 时，证书页读不出完整证书；点续签后弹出「无法确认当前 Seal 的签名证书」，恢复文案「先用电脑的原签名工具覆盖安装一次 Seal，再回来续签」。日志另出现 SEAL-SELF-105「无法确认当前 Seal 的签名身份」。
- **根因**：当前正在运行的 Seal 由 iloader 用非标准签名结构签名，主程序/网络扩展的真实 CMS 签名者无法被 `AppBundleSigningIdentityReader` 读出。身份读不完整 → 既不敢撤销（SEAL-CERT-232）、也不敢覆盖装自己（SEAL-SELF-105）。这是设备现实状态，不是代码 bug，且不能靠弱化身份校验绕过。
- **修复/处置**：电脑覆盖安装（不卸载），保持同一 Apple ID（sunuannian1@gmail.com）、Team（CT8QZ7352B）、主/扩展 Bundle ID 一致，改用能产出标准签名的签名工具。
- **涉及文件**：`Seal/Infrastructure/Renewal/AppBundleSigningIdentityReader.swift`、`Seal/Core/Renewal/SelfReplacementCoordinator.swift`。
- **验证状态**：待用户电脑覆盖安装后，回读新日志确认身份读取完整。

### 2026-09-16 · 证书轮换在无法确认 Seal 真实签名证书时仍撤销

- **现象**：续签 Seal 时，即使读不出运行中 Seal 的 signer，日志仍出现「证书轮换：撤销 …序列号，原因=无本机私钥，运行中Seal=否」，把唯一一张无本机私钥的证书当普通孤儿撤了，随后创建新证书签名，但安装被 SEAL-SELF-105 拦住。
- **根因**：`rotateCertificatesAndCreateIdentity` 未区分「签名/续签 Seal 本身」与「签名普通 App」。读不出 signer 时把 `sealActualSignerSerials` 置空，导致运行中 Seal 证书被误标为「运行中Seal=否」进入可撤销集合。
- **修复**：新增 `sealSignerConfirmed` 标志；`isSeal == true` 且读不出运行身份时，前置抛出 `SEAL-CERT-232`（无法确认当前 Seal 的签名证书），在撤销发生前就止步。普通 App 不涉及 Seal 身份，不受影响。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`。
- **验证状态**：`Scripts/verify-release-safety.py`（128 源码回归 + 54 变异）全过，CI build-package / rork-sign-tests / swift-regression 全绿；真机日志确认旧版误撤、新版已止步于 SEAL-CERT-232。

### 2026-09-16 · SelfReplacementFailure 被兜成笼统 SEAL-SIGN-500

- **现象**：自更新安装分支抛出的 `SelfReplacementFailure` 未被映射为 `ImportFailure`，被 `AppsViewModel.unexpectedSigningFailure` 兜成笼统「SEAL-SIGN-500」，用户拿不到可操作指引。
- **根因**：`SelfReplacementFailure` 四种 case（runningIdentityUnknown / bundleShapeChanged / localSigningIdentityUnavailable / candidateChanged）未做错误码映射。
- **修复**：在 `SigningCoordinator` 新增 `selfReplacementFailure(_:)`，映射为 SEAL-SELF-105～108，兜底 SEAL-SELF-109，标题统一「Seal 自更新中止」；自更新安装分支 try/catch 捕获并转 `ImportFailure`。
- **涉及文件**：`Seal/Core/Signing/SigningCoordinator.swift`。
- **验证状态**：提交 `edc7971`，CI build-package / rork-sign-tests / swift-regression 全绿，回归测试未破坏。