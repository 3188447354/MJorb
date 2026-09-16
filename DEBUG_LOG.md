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

---

## 历史记录

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