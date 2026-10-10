# Seal 错误契约源码审计

- 开始日期：2026-10-10
- 状态：进行中；本文件只记录经源码追溯确认的结论。
- 范围：所有可能进入应用界面的 `ImportFailure`、其包装点、日志码与恢复按钮。仅内部信息日志不作为用户错误处理。

## 审计规则

每一个用户可见失败必须沿以下链路记录，缺任一项不得给出确定性用户操作：

```
原始触发条件
  -> 产生/转换错误的源文件与符号
  -> 上层包装与重试
  -> 日志码
  -> SwiftUI 展示入口
  -> 唯一可执行恢复动作
```

分类不能从错误码前缀或旧文案推断。必须以产生点的状态、底层返回值或操作后的读回结果为证据。

## 基线发现

### 1. 当前模型缺少机器可判定的恢复语义

`Seal/Core/Import/ImportFailure.swift` 当前只保存 `title`、`reason`、`recovery` 与 `code`。
它没有根因类别、证据等级、是否可重试、恢复动作或 App 内目标入口。

结果是 Portal、签名协调器、安装通道、单应用 ViewModel 和批量续签各自重新包装错误；同一个底层错误可在不同入口变成不同用户文案。

### 2. 已确认的错误归因丢失：Apple 请求超时

用户日志中的 `NSURLErrorDomain -1001` 发生于 Apple `listTeams.action` 请求。
`AppleServiceFailurePolicy.isNetworkError` 与 `ApplePortalSigningFailure.make` 已能将该类错误识别为 `SEAL-NET-102`。

但以下两个单应用路径的裸 `catch` 直接写入 `SEAL-SIGN-500` 并调用 `unexpectedSigningFailure`：

- `Seal/Features/Apps/AppsViewModel.swift`：证书撤销后自动重签收尾。
- `Seal/Features/Apps/AppsViewModel.swift`：已签名包重新安装。

因此，底层网络超时被错误改写成“未知错误”。此项后续必须先写回归测试，再在共用归一化边界修复；不得只改弹窗文案。

### 3. 已确认的确定性状态：续签不能继续

`Seal/Infrastructure/Signing/ApplePortalSigningService.swift` 在 profile-only 续签找不到已存在的 App ID 时抛出 `SEAL-PROFILE-337`。
源码明确说明该路径不会注册新的 App ID，因此它不是网络或 LocalDevVPN 问题，唯一正确操作是完整重签。

### 4. 现有前缀路由仍是风险点

`Seal/Features/Settings/InstallFailureSettingsRoute.swift` 对认证和证书仍通过 `SEAL-AUTH-`、`SEAL-CERT-` 前缀选择设置页。
这与安装模块已经采用的“显式错误码集合”标准不一致。后续迁移必须将所有自动路由改为结构化恢复动作，不能扩大前缀匹配。

### 5. 旧帮助页不是错误恢复机制

旧方案使用 `docs/error-catalog/` 生成 `Seal/Resources/ErrorHelp/help-index.json`，由 `ErrorHelpView` 展示。

## 已确认的迁移边界（2026-10-10）

用户明确要求不保留旧方案。因此本次重构完成时，以下内容会整体移除，不能以“过渡页”或隐藏入口形式继续存在：

1. 设置页、日志页、签名/续签失败页中的“错误帮助”入口与详情页；
2. `ErrorHelpView`、`ErrorKnowledgeStore`、随 App 打包的 `help-index.json`，以及只为它们服务的测试、生成脚本和 CI 校验；
3. 以错误码前缀、静态文案或泛化网络建议推断用户操作的旧分流。

保留的只有两类非 UI 数据：运行日志里的稳定错误码（用于排障和兼容历史日志），以及新的源码审计表。新 UI 必须直接消费结构化的“已确认操作”，不再打开另一个帮助页面。

删除会与新的结构化错误合同在同一变更中落地，避免出现“旧页面没了、当前失败页也没有可执行操作”的空窗。

## 阶段 A：账号与 Apple Portal（已逐段追到 2026-10-10）

| 来源条件 | 当前代码出口 | 证据链 | 现有问题 | 新合同中的唯一操作 |
| --- | --- | --- | --- | --- |
| Apple 请求超时（例如 `NSURLErrorDomain -1001`） | `AppleAuthenticationFailure.make` / `ApplePortalSigningFailure.make` 会先归为网络失败；但 `AppsViewModel` 的直接 `catch` 又写成 `SEAL-SIGN-500` | `AppleServiceFailurePolicy.isNetworkError` 收录 `.timedOut`；`AppsViewModel` 第 1731、1996 行无条件覆写 | 同一个底层超时会在单签/直接续签中丢掉“网络请求未完成”的事实，变成“未知错误” | **检查能访问 Apple 开发者服务的网络后重试**；不改变 Apple ID、证书或 App ID 状态 |
| Apple 返回限流 | `AppleServiceFailurePolicy.rateLimitedFailure` | 认证和 Portal 工厂均先检查 rate limit | 旧文案把某类网络出口具体化为“梯子”，不适合作为通用操作 | **等待后重试**；不得引导重验 Apple ID |
| 登录凭据被 Apple 明确拒绝 | `SEAL-AUTH-102a/102b/102d` | `ALTAppleAPIError.incorrectCredentials` 的专门分支 | 当前又在若干批量 UI 包装为泛化“Apple ID 不可用” | **到“我的”重新验证该 Apple ID** |
| 二次验证码错误/过期 | `SEAL-AUTH-101` | `ALTAppleAPIError.incorrectVerificationCode` 专门分支 | 无结构化操作，UI 仍靠文字与 code 推断 | **获取最新验证码后重新验证** |
| 仅更新描述文件时 Apple 找不到已存在 App ID | `SEAL-PROFILE-337` | `renewalProvisioningProfiles` 只 `fetchAppIDs`；找不到时明确不注册 App ID | 若被外层泛化，不会告诉用户必须换流程 | **执行完整重签**；不是 Wi-Fi、LocalDevVPN 或重新验证账号 |
| 本地 Anisette / Apple 认证握手异常 | `SEAL-ANI-115`、`SEAL-AUTH-107h` | `AppleAccountClient.authenticateOnce` 的专门分支 | 旧 reason 直接拼入底层描述且混合多种猜测操作 | 保留为独立“认证环境”条件；在后续逐项审计后给出唯一、可验证操作，不能归到网络或凭据 |

### 阶段 A 的合同缺口

- `ImportFailure` 目前只有四段字符串，调用方无法区分“网络超时”“账号凭据被拒绝”“必须完整重签”等已由源码确认的事实。
- `AppleServiceFailurePolicy`、`RenewalCoordinator.isRetryable`、`AppsViewModel.signingFailure(for:)` 分别使用错误类型、错误码前缀和字符串回退，故同一根因经过不同链路会得到不同结果。
- 下一阶段会继续沿 `ApplePortalSigningService` 的证书、设备、App ID、描述文件分支逐条建表；尚未对任何未读分支下结论。

## 清单口径校验（审计前置条件）

当前以 Swift 字面量 `code: "SEAL-…"` 扫描，只得到 **273** 个唯一代码；`AGENTS.md` 记录为 327 个。二者不能混用，也不能把任一数字当作“已覆盖总数”。差额可能来自常量、测试/脚本生成、已删除但仍被文档记录的代码，必须在新 CI 守卫中以同一解析器统一定义。

按当前可直接定位的字面量，最高风险模块为：`INSTALL` 52、`PROFILE` 47、`CERT` 32、`IPA` 31、`RENEW` 23、`SELF` 18、`AUTH` 17、`PAIR` 17、`SIGN` 16、`STORAGE` 13。审计顺序将按执行链路而非数量推进，避免漏掉少量但会让用户无法恢复的错误。

## 阶段 B：签名、安装与设备通道（进行中）

### 已确认应保留的事实分支

| 已确认条件 | 代表代码 | 用户下一步 | 不应显示成 |
| --- | --- | --- | --- |
| 配对资料缺失或属于另一台设备 | `SEAL-PAIR-203b`、`SEAL-PAIR-205`、`SEAL-PAIR-211` | 重新配对当前 iPhone | Wi-Fi、Apple ID、重新签名 |
| iPhone 未信任当前配对 | `SEAL-INSTALL-704` | 在 iPhone 完成信任后重试 | LocalDevVPN 未连接 |
| LocalDevVPN 接口存在，但设备服务端口不可达 | `SEAL-INSTALL-710` | 检查 LocalDevVPN 是否真正连接后重试 | 泛化“未知错误”或重新签名 |
| iOS 设备存储不足 | `SEAL-INSTALL-702s` | 清理 iPhone 存储后重试 | 网络或 Apple ID 问题 |
| iOS 明确拒绝安装 | `SEAL-INSTALL-702l` | 基于设备返回的具体拒绝原因操作；不能自动重传 | “检查 Wi-Fi” |
| 安装等待超时，底层同步安装可能还在运行 | `SEAL-INSTALL-702t` | 等待后回列表核验是否已装上；确认未装才重试 | 立即重新安装 |
| 已签名包缺失、损坏、过期或与记录不符 | `SEAL-INSTALL-711…730` 显式集合 | 重新签名 | LocalDevVPN 或重新配对 |
| profile-only 续签的 App ID / 身份 / 证书前提不成立 | `SEAL-PROFILE-331…337` | 执行完整重签 | 网络、重新验证 Apple ID |

### 本阶段已确认的根因丢失点

1. `SigningCoordinator` 与 `AppsViewModel` 都存在非 `ImportFailure` 的 `500` 兜底。它们保留了脱敏诊断日志，但用户操作被降级为“知道了”。其中 `AppsViewModel` 已确认会吞掉 Apple 网络超时；`SigningCoordinator` 还需逐一追踪每个原始错误进入兜底前的来源。
2. `InstallFailureActionPolicy` 的显式集合是正确方向，但它只覆盖安装族；其它 UI 仍有 `hasPrefix("SEAL-AUTH-")`、`hasPrefix("SEAL-NET-")` 等分流，不能成为新的全局合同。
3. 设备通道的底层分类已比旧文案精确，但 `SEAL-INSTALL-701/706b/708` 仍把“解锁、Wi-Fi、LocalDevVPN”等多个未验证条件绑在同一提示中。后续将只在诊断确实表明隧道/端口问题时展示 LocalDevVPN 操作；配对、信任、存储、iOS 拒绝等分支保持独立。

## 阶段 C：用户界面、日志与旧帮助链（已追踪）

### 旧帮助链的实际入口

- 设置页：`SettingsRoute.errorHelp` → `ErrorHelpLibraryView`；
- 签名/续签失败弹层：`AppDetailView`、`AppSigningSheet`、`AppsRootView` 的“查看解决办法”；
- 日志错误项：`LogViewerView` 的“查看解决办法”；
- 数据源：`ErrorKnowledgeStore.bundled()` → `Seal/Resources/ErrorHelp/help-index.json`。

新合同应让失败视图直接显示唯一操作按钮和必要的简短说明；日志项只保留“复制诊断”，不能再跳转到静态知识库。

### 日志导出的源码结论与待验证边界

当前源码中 `SettingsViewModel.materializeLogExport()` 调用 `SealLogStore.materializeExport()`，后者会创建 Documents 目录、把当前内存缓冲导出到 `Seal-log.txt`，**写入成功后才返回 URL**。因此“日志文件不存在”并不是这段当前源码应产生的正常结果。

待用真机/构建号进一步核验的可能边界只有两类，现阶段不下结论：

1. 实机运行的不是包含该实现的构建；
2. `logStore` 未注入、导出写入失败，或分享层无法打开返回的 URL。

新错误合同会把这三类分开记录和呈现；不能继续用同一个 `SEAL-LOG-002` 覆盖全部情况。

### 仍在使用前缀猜测的 UI 路由

`InstallFailureSettingsRoute` 已对安装/配对做了部分显式集合，但仍以 `SEAL-AUTH-*` 和 `SEAL-CERT-*` 前缀决定跳转。下一步将逐项判断这些代码是否真的都应跳到同一设置页；新合同不以字符串前缀决定按钮行为。

## 阶段 D：导入、存储与可恢复事务（进行中）

导入与文件存储并非“任意失败都提示清理空间”：源码已经区分了下列结果，重构不得压平。

| 条件 | 代表代码 | 正确操作 |
| --- | --- | --- |
| 外层 ZIP、Payload/Info.plist/Bundle ID 不符合 IPA 结构 | `SEAL-IPA-101…106` | 选择正确、完整的 IPA；外层压缩包先解压 |
| IPA 包含不安全路径或超出安全解压限制 | `SEAL-IPA-104` 及大小限制分支 | 停止导入，换可信来源的 IPA |
| 文件暂存/提交失败 | `SEAL-IPA-203/205/212` | 先确认本机存储；只在底层确为写入失败时提示释放空间 |
| 事务回滚/启动恢复尚未完成 | `SEAL-IPA-ROLLBACK-001`、`SEAL-IPA-213` | 不要求用户重复导入；下次启动继续恢复 |
| 临时文件清理失败 | `SEAL-STORAGE-003` | 在存储维护中执行对应的临时文件清理；不能删除原始 IPA 或可续签所需数据 |

这部分将与“签名包清理”重构一起处理：`Original.ipa`、`Signed.ipa`、记录、证书/私钥、设备描述文件不是同一种数据，不能用一个“清理签名包”按钮混删。具体删除策略会以续签链路的真实读取点为依据，在审计到该链路后单独列出。

## 阶段 E：单项与批量续签的一致性（已确认两处丢失）

1. 批量续签会在重试用尽后通过 `RenewalCoordinator.normalize(_:)` 把所有非 `ImportFailure` 统一改成 `SEAL-RENEW-500`，并给出“检查网络和设备连接”。这会把证书、存储、队列持久化或未分类代码错误误导为网络/设备问题。
2. `AppsViewModel.renewalGuidance(for:)` 把所有 `SEAL-AUTH-*` 重新写成“可能还没添加账号、账号已被删除，或登录会话过期”。这会覆盖源码已经精确确认的验证码错误、凭据明确被拒绝、团队不存在、只更新描述文件前提不满足等不同情形。

因此，同一个底层错误目前至少有三种呈现通道：单项签名/续签、批量续签、已签名包重新安装。新合同必须在最初的错误工厂完成一次分类，之后各通道只能透传同一个操作对象；不允许二次猜测和改写。
该页面不执行恢复动作，且用户已明确要求移除。它不应成为新错误契约的 UI 依赖；源代码审计证据和脱敏日志仍可保留为工程资料。

## 分层审计顺序

| 阶段 | 链路 | 产生点 | 必须确认的输出 |
|---|---|---|---|
| A | Apple 账号与开发者门户 | `AppleAccountClient`、`ApplePortalSigningService` | 账号、限流、网络、设备注册、证书、App ID、描述文件各自的证据与动作 |
| B | 签名与签名产物 | `SigningCoordinator`、`SigningWorkspace`、`PreInstallValidation` | 证书轮换、原包、签名产物、权限、重签决策 |
| C | LocalDevVPN、配对与安装 | `MinimuxerInstallChannel`、`InstallChannelDiagnostic` | 配对、隧道、设备服务、设备存储、iOS 确定性拒绝、安装结果不确定 |
| D | 单续签与全部续签 | `AppsViewModel`、`RenewalCoordinator` | 同一底层错误跨入口的统一分类、重试预算与批量结果语义 |
| E | 导入、存储、日志与历史 | `ImportWorkflow`、`AppFileStore`、`SealLogStore` | 本地状态损坏、文件缺失、导出失败、可安全重试与需日志支持 |

## 新契约的验收要求

1. 产生点必须产出结构化类别与恢复动作，界面不从文字或错误码前缀猜测。
2. 单签、单续签、全部续签对同一底层失败给出同一恢复动作。
3. 每条“重新签名”“重新配对”“连接 Wi-Fi 并开启 LocalDevVPN”“重新验证 Apple ID”等操作，都必须有源码证据证明它能改变该失败条件。
4. 无法确认根因时只给“导出日志”，不得使用“ID 失效”“需要重签名”等确定性词语。
5. 每个迁移项都有失败前的回归测试、源码/脚本静态约束和完整 iOS CI 验证。
