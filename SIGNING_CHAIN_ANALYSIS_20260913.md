# Seal 签名-安装-续签-内部更新链路分析

日期：2026-09-13
范围：静态阅读 `Seal/`、`SealTests/`、`Config/` 和相关设计/调试文档。
结论：本次只做分析，未修改任何源代码、配置或测试文件。

## 一、总判断

当前项目已经具备完整的主干：

```text
导入 IPA
  -> Apple ID/Team 选择
  -> Keychain 会话读取
  -> Apple Portal 获取 Team/设备/App ID/描述文件/证书
  -> RorkSign 重签
  -> IPA 校验与保存
  -> Minimuxer/LocalDevVPN 安装
  -> 设备端验证
  -> AppRecord/签名历史回写
```

但“正常工作”依赖多个隐含前提，且恢复链没有闭合。最关键的不是签名算法，而是 Apple ID 会话失效、安装包确定性错误、批量重试和自更新失败恢复。当前不能判定为链路逻辑完全正常。

## 二、按链路结论

| 链路 | 判断 | 结论 |
|---|---|---|
| IPA 导入/记录 | 基本正常 | 普通导入与 Seal 自更新复用记录 ID，设计清晰；自更新记录在重签前暂存为 installed，属于可恢复但需要明确 pending 语义 |
| Apple ID 添加 | 基本正常 | 添加、2FA、Team 查询、Keychain 保存链路存在 |
| Apple ID 续期/重新验证 | **不完整** | 签名路径没有真正接入 `reauthenticate()` 或验证码回调；会话过期只能跳设置页 |
| 签名证书 | 基本正常但有高风险降级 | 证书创建、P12 保存、失败回滚存在；Apple 证书列表拉取失败时可能无条件复用过期/被撤销本地证书 |
| Provisioning Profile | 有校验 | Team、Bundle ID、设备、证书和有效期有校验；设备端 profile 长期累积清理尚未接入 |
| 安装 | 主流程存在 | 通道、UDID、上传、安装后查验基本成链；但错误 UI 将结构性签名包问题误导为重新安装 |
| 单个续签 | 基本正常 | `forceResign: true` 能避免直接复用旧签名包 |
| 批量续签 | **恢复逻辑不正常** | “重试失败项”调用全量 `refreshAll()`，会重新处理已成功应用 |
| 内部更新 | 主流程存在但未闭环 | 下载、导入、自动打开签名抽屉存在；导入失败仍删除 IPA，版本比较也不是语义版本比较 |
| 状态持久化 | **语义不一致** | `needsVerification`、失败原因策略存在，但当前生产路径基本不写入，旧状态还会被启动修复 |

## 三、阻断级问题

### 🔴 1. 签名过程的 Apple ID 重新认证和 2FA 回调未接通

证据：

- `Seal/Application/AppContainer.swift:64-81` 创建 `VerificationCodeBroker`，并把验证码闭包传给 `ApplePortalSigningService`。
- `Seal/Infrastructure/Signing/ApplePortalSigningService.swift:237-253` 仅保存 `accountClient` 和 `verificationCodeProvider`。
- 全文件搜索没有找到这两个成员在认证/签名过程中被调用。
- `Seal/Infrastructure/Accounts/AppleAccountClient.swift:140-160` 的 `reauthenticate()` 只有定义，没有生产调用点。
- `ApplePortalSigningService.swift:379-389` 直接用旧 `authToken` 构造 `ALTAppleAPISession` 并调用 `fetchTeams()`。
- `ApplePortalSigningService.swift:293-302` 对 `SEAL-AUTH-107` 直接转成“去设置页重新验证”。

实际结果：

```text
签名/续签 -> 旧 authToken -> Apple 返回 1100/session expired
          -> 当前签名流程不会弹验证码，也不会自动 reauthenticate
          -> 只能退出到设置页手动验证
```

因此 `SigningProgressView` 中的验证码弹窗不是当前签名链路的有效恢复点。批量续签还显式关闭交互式提示（`AppsViewModel.swift:1207-1211`），所以批量续签只能依赖有效缓存会话。

### 🔴 2. 安装错误恢复动作错误：所有 `SEAL-INSTALL-*` 都走“重新安装”

证据：

- `Seal/Features/Apps/SigningProgressView.swift:393-415`：`isInstallChannelFailure()` 只判断 `failure.code.hasPrefix("SEAL-INSTALL-")`，按钮统一显示“重新安装”，并调用 `retryInstallationForCurrentSigningSession()`。
- `Seal/Core/Signing/SigningCoordinator.swift:280-381` 明确把以下错误定义为“重新签名”：
  - `711` 文件缺失
  - `712` SHA-256 损坏
  - `713` 描述文件过期
  - `714/714a` 当前设备不匹配
  - `716` Bundle ID 无效
  - `717` Team 不一致
  - `718` 描述文件不含保存证书
  - `719` 签名包记录不完整
- `AppsViewModel.swift:1044-1056` 的重试只重新读取同一个签名包并安装。

实际结果：签名包损坏、过期、设备不在 profile 中时，重复安装不会改变包内容，用户会陷入无效重试。错误码本身已有正确 recovery 文案，但 UI 分类覆盖了它。

### 🔴 3. “重试失败项”实际是全量批量续签

证据：

- `Seal/Features/Apps/BatchRefreshView.swift:149-155`：按钮“重试失败项”调用 `viewModel.refreshAll()`。
- `Seal/Features/Apps/AppsViewModel.swift:1151-1153`：`refreshAll()` 直接调用 `startBatchRefresh()`。
- `Seal/Core/Renewal/RefreshPlanner.swift:4-27` 只按已安装状态生成全量队列，没有失败 App ID 参数。

实际结果：

```text
第 1 轮：A 成功，B 失败，C 成功
点击“重试失败项”
第 2 轮：A、B、C 全部再次签名/上传/安装
```

这会增加 Apple Portal 请求、设备安装压力和免费账号侧不确定性，且 UI 文案与实际行为不一致。

## 四、高风险问题

### 🟡 4. Apple 证书查询失败时无条件复用本地证书

`ApplePortalSigningService.swift:623-646`：本地 P12 可读时，如果 `fetchCertificates()` 成功则检查远端序列号；但如果查询抛错，代码直接返回本地 `SigningIdentity`。

风险：网络失败、限流、会话失效、Apple 拒绝都会被归并成“可以复用本地证书”。当前代码没有在该快速分支使用 `X509CertificateValidityReader` 检查 `notAfter`，所以过期或已撤销证书可能一路进入描述文件/签名，最后才在设备验证阶段暴露。

`DEBUG_LOG.md:127-144` 已记录过“尚未验证/1100/旧证书复用”关联现象，这个静态风险与历史现象相互印证，但最终仍需真机取得内嵌 profile 和证书有效期做定性。

### 🟡 5. 账号验证状态模型与生产行为不一致

证据：

- `AccountStatus.needsVerification` 会阻止选择：`Seal/Core/Accounts/AccountStatus.swift:1-8`。
- `SettingsViewModel.swift:1630-1636` 的 `persistVerificationFailure()` 是空实现。
- `AppleServiceFailurePolicy.swift:40-59` 只匹配旧的精确错误码 `SEAL-AUTH-102/105/106`。
- 当前生产错误码大量带后缀，例如 `102a/102b`、`105a/105b/105c/105d/105e`。
- `SettingsViewModel.swift:1562-1564` 对验证失败只抛错误，不写账号状态。
- 启动时 `repairLegacyAccountStatuses()` 又会把部分旧 `needsVerification` 修回 `availableOffline`。

结论：当前实际策略更接近“Apple ID 永久保留，失败只提示用户”，但状态枚举和策略函数仍保留“标记为需要验证”的旧语义。不是单一崩溃点，却会造成 UI、账号可选性和恢复提示不一致。

### 🟡 6. 证书设置和库存查询的 callback 没有统一超时

- `ApplePortalCertificateService.swift:211-270` 的 Team、证书、创建、撤销 callback 直接使用 continuation。
- `ApplePortalInventoryService.swift:200-248` 的 Team、证书、App ID 查询同样没有服务级超时。
- 签名主服务有 `withAppleTimeout`，但设置页证书/库存路径没有对齐。

风险：Apple callback 不返回时，设置页可能无限 loading；这与签名页有超时、设置页无超时的行为不一致。

### 🟡 7. 应用内更新下载文件无论导入成功失败都会删除

`Seal/App/RootTabView.swift:110-115`：

```text
await importSelfUpdateFile(localURL)
deleteDownloadedFile(localURL)
```

而 `AppsViewModel.importSelfUpdateFile(_:)` 返回 `Void`（`AppsViewModel.swift:630-632`），调用方无法判断导入结果。

实际结果：IPA 解析失败、存储失败或导入事务失败时，原下载文件仍被删除，用户只能重新下载，无法重试同一文件。

### 🟡 8. 更新检查只判断“版本不同”，没有判断远端版本更高

`Seal/Infrastructure/UpdateChecker.swift:35-41` 只排除完全相同的版本或 `v` 前缀版本，没有使用 `Version.compare` 判断远端版本是否大于当前版本。

风险：GitHub `latest` 因回滚、发布顺序或 tag 异常返回旧版本时，Seal 仍可能提示并下载旧 IPA。

### 🟡 9. Seal 自续签保护器和 Tracker 未接入生产路径

- `SelfRenewalContextValidator.validate()` 只有定义与测试调用。
- `SelfRenewalTracker.markPending()` / `markCompletedIfMatches()` 只有定义与测试/源码定义，没有生产调用。
- 实际 Seal 入口在 `AppsViewModel.swift:779-809` 使用 `SelfAppMetadata.current()` 和 Team 比对，未调用统一 validator。
- `SelfRenewalTracker.markCompletedIfMatches()` 读取了 `version` 参数却只按 Bundle ID 清理 pending 状态（`SelfRenewalTracker.swift:16-26`）。

结论：测试所覆盖的保护逻辑并不等于线上执行的保护逻辑；未来接入 Tracker 时还需要把版本纳入匹配条件。

### 🟡 10. 设备诊断顶层 catch 会掩盖真实步骤

`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift:205-209`：诊断期间任何未包装的异常最终都返回 `.pairingFile` / missing pairing failure。

但诊断过程包含配对文件、VPN、Minimuxer、UDID、RSD/TLS 和安装服务多个步骤。实际是 FFI、网络、设备断开或目录异常时，用户可能被误导为“配对文件损坏”。

## 五、已做得比较好的部分

- `SigningCoordinator.signAndInstall()` 在签名、保存签名包、安装失败时会区分原始状态，并记录 `lastInstallFailureCode/Reason`。
- 新证书写入存在 Keychain + 账号记录校验和补偿回滚（`SigningCoordinator.swift:410-450`）。
- 已保存签名包安装前有 SHA-256、有效期、设备、Team、证书序列号和 Bundle ID 检查。
- `forceResign: true` 用于单个/批量续签，避免直接复用旧签名包。
- Seal 自更新通过 `makeSelfUpdateRecord()` 复用已有 ID，避免正常更新后产生重复 Seal 记录。
- `SelfAppRegistrar` 对“待安装自更新源”做了文件存在和版本不低于当前运行版本的保护，说明启动恢复方向是对的。
- 设备安装进度已区分上传完成与安装开始，`DEBUG_LOG.md` 中的哨兵设计与代码意图一致。

## 六、测试覆盖缺口

当前测试更偏模型和局部校验，未覆盖以下真实关键路径：

1. 会话过期后签名流程是否能触发 reauthenticate/2FA。
2. `verificationCodeProvider` 是否被消费以及取消验证码后的状态清理。
3. `SEAL-INSTALL-711` 至 `730` 的 UI 恢复动作映射。
4. 批量部分成功后只重试失败 App。
5. 批量重试次数、取消、队列恢复和账号失败后的队列状态。
6. Apple 证书列表查询超时、失败时的本地证书有效期策略。
7. 自更新下载后导入失败是否保留源 IPA。
8. 远端版本低于当前版本时不应提示更新。
9. SelfRenewalContextValidator/Tracker 在实际自更新入口被调用。
10. 证书设置页和库存查询 callback 超时。

## 七、建议修复顺序（不代表本次已修改）

### 第一批：先消除错误恢复死循环

1. 将安装错误分为“可直接重新安装”和“必须重新签名/重新生成 profile”两类；优先依据 `ImportFailure.recovery` 或明确错误码集合，不要用 `SEAL-INSTALL-*` 总前缀分类。
2. 批量刷新保留上一轮失败 App ID 集合；“重试失败项”只传该集合给 planner/coordinator。
3. `importSelfUpdateFile` 返回成功/失败结果，只有导入事务成功后才删除下载源 IPA。

### 第二批：闭合 Apple ID 会话恢复

1. 明确产品策略：签名时自动重新认证，还是统一要求去设置页验证；不要同时保留“有验证码 broker/reauthenticate”但运行时不调用的半成品。
2. 如果采用自动重新认证，处理 1100、2FA、取消、密码更新、Keychain 原子保存和批量模式禁用交互的分支。
3. 如果坚持设置页人工验证，应删除或重构签名路径中的死成员，并让错误状态、按钮和文案明确反映“需离开当前流程”。

### 第三批：证书和状态一致性

1. 本地证书快速复用前至少校验 X.509 `notAfter`；对“会话失效”与“网络暂时失败”区别处理，不能所有 fetchCertificates 错误都 fallback。
2. 统一当前错误码和 `AppleServiceFailurePolicy` 的匹配规则，决定哪些错误真的写入 `needsVerification`。
3. 为设置页证书/库存 callback 加与签名主路径一致的超时和错误归类。

### 第四批：更新与自续签保护

1. 用语义版本比较确认远端版本大于当前版本。
2. 将 `SelfRenewalContextValidator` 接入实际 Seal 自续签入口，或删除测试覆盖但线上不执行的伪保护层。
3. Tracker 的完成匹配加入版本，并补上 pending/completed 的实际生产调用。
4. 规划设备端 profile 按当前 Bundle ID 清理旧记录；禁止无条件清理全部 profile。

## 八、最终结论

签名、证书、Provisioning、安装的“成功路径”已经搭起来，不能说完全失控；但错误恢复和状态闭环明显不完整。当前最可能导致用户感知为“报错、有问题、续签失败、更新失败”的根因优先级是：

1. **Apple ID 会话过期后当前签名流程没有重新认证/验证码闭环。**
2. **签名包已损坏/过期时 UI 仍重复安装同一个包，而不是重新签名。**
3. **批量“重试失败项”会全量重跑。**
4. **Apple 证书列表暂时不可用时可能复用过期/失效本地证书。**
5. **自更新导入失败会丢失下载源，更新检查还可能接受旧版本。**

因此，对“签名-安装-续签-内部更新-Apple ID-签名证书逻辑是否正常”的直接回答是：**主成功链路基本存在，但恢复链和状态链不正常，暂不适合把当前实现视为已闭环。**
