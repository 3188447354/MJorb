# Seal 结构化失败合同设计

## 目标

让签名、单项续签、批量续签、安装、导入、日志导出对同一根因展示同一条可执行操作；移除旧“错误帮助”页面、静态知识库和基于错误码前缀的猜测式路由。

这不是一轮文案替换，而是将 Seal 的失败处理提升为可演进的领域合同：**事实采集、领域分类、用户动作、界面呈现、日志与审计**五层各自单责，后续新增功能不能绕过这条链。

## 不变约束

- 运行日志继续保存稳定错误码及脱敏诊断，历史日志仍可阅读。
- Apple Portal、设备通道、描述文件、证书和签名包不能被同一句“检查 Wi-Fi/LocalDevVPN”覆盖。
- profile-only 续签找不到 App ID（`SEAL-PROFILE-337`）必须引导完整重签，不能提示网络或重新验证账号。
- 设备配对、设备信任、隧道端口、设备存储、iOS 拒绝、安装超时必须保持独立语义。
- 签名/续签语义继续对齐现有 SideStore 对照结论：profile-only 不创建 App ID，完整重签才重建身份。
- 稳定错误码是对外诊断接口：已发布代码不得重新解释或复用；只能新增，弃用必须保留迁移说明。
- 用户界面只说已被源码确认的事实和下一步操作；底层域、URL、异常链只进入可复制诊断与本地日志。
- 敏感信息（Apple ID、UDID、设备名称、认证票据、完整请求 URL、文件绝对路径）写入日志前必须脱敏；不得进入用户可见正文。

## 设计

### 1. 失败合同

`ImportFailure` 不再只是四段文案。它升级为稳定的失败记录，并新增结构化字段：

- `condition`：源码已经确认的事实，例如 `appleServiceUnavailable`、`appleRateLimited`、`credentialsRejected`、`verificationCodeRejected`、`fullResignRequired`、`pairingRequired`、`deviceTrustRequired`、`tunnelUnavailable`、`deviceStorageFull`、`installationStillRunning`、`signedArtifactInvalid`、`localStorageWriteFailed`、`logServiceUnavailable`、`unexpected`。
- `action`：唯一用户动作，例如 `retry`、`waitThenRetry`、`reauthenticateAccount`、`enterNewVerificationCode`、`fullResign`、`repairPairing`、`trustDevice`、`openLocalDevVPN`、`freeDeviceStorage`、`checkInstallationResult`、`reinstallFromSignedArtifact`、`reimportIPA`、`restartSeal`、`copyDiagnostics`。
- `route`：可选核心导航意图（账户、证书、配对、LocalDevVPN），只有动作确实需要跳转才赋值；不从错误码字符串推断。核心层只认识 `FailureRoute`，SwiftUI 层才把它单向映射到具体 `SettingsRoute`，避免核心领域依赖界面模块。
- `retryDisposition`：`none`、`automatic`、`manual`、`waitForInFlightWork`。

再新增不可变的上下文：

- `operation`：`sign`、`renew`、`batchRenew`、`install`、`importIPA`、`exportLog`；用于审计与测试，不能驱动用户文案。
- `origin`：产生分类的边界（认证、Portal、描述文件、设备通道、安装器、文件存储、日志服务）；用于定位“事实在哪里丢失”。
- `diagnosticID`：每次失败生成的关联 ID。UI、结构化日志和导出日志都记录同一个 ID，便于一次反馈定位，不暴露隐私数据。

`title`、`reason`、`recovery`、`code` 继续保留，以维持日志、SwiftUI 和历史记录兼容；UI 文案只由结构化动作生成，不再让调用方按 code 改写文字。

### 2. 分类只发生在错误边界

新增一个纯函数分类器，输入原始 `Error` 加上操作上下文（Apple 认证、Portal、签名、设备通道、安装、导入、日志），输出一个完整 `ImportFailure`。分类器是唯一允许把原始 `Error` 变成用户动作的边界；下游不可二次猜测。

- Apple 超时/限流/凭据/验证码/Anisette 各自归类；`URLError.timedOut` 不能再落进 `SEAL-SIGN-500`。
- `SEAL-PROFILE-331...337`、证书缺私钥、签名包缺失/损坏等已是确定性业务错误，原样透传并附上明确动作。
- `MinimuxerInstallChannel` 保留现有的细分诊断；它将诊断映射成结构化条件，而非在每个错误文案里堆叠 Wi-Fi、VPN、解锁等猜测。
- 真正无法分类的错误才得到 `unexpected + copyDiagnostics`；日志记录域、码和脱敏诊断，但 UI 不假装知道原因。

分类优先级固定为：确定性业务状态（如 App ID 缺失）→ 设备诊断 → Apple 服务策略 → 本地文件/日志边界 → 未知错误。优先级以测试锁定，避免“超时”覆盖了更具体的确定性状态。

### 3. 单一呈现路径

`AppsViewModel`、`RenewalCoordinator`、`SigningCoordinator`、`SettingsViewModel` 只能透传或调用分类器，禁止重新用 `hasPrefix`、`contains` 或固定 500 文案解释失败。

- 单项签名、单项续签、批量续签、缓存签名包安装共用同一失败合同。
- 批量重试只读取 `retryDisposition`；不再把所有未包装错误改写为 `SEAL-RENEW-500`。
- 按钮标题、动作、设置页路由只读取 `action` 与 `route`。

### 4. 删除旧帮助链

删除 `ErrorHelpView`、`ErrorKnowledgeStore`、`help-index.json`、相关测试、错误目录生成和 CI 校验；删除设置项和所有“查看解决办法”次级弹层。

失败弹层直接显示：简短事实说明、一枚与 `action` 对应的主按钮；无法自动操作时仅显示“复制诊断”。日志页保留复制错误信息，不再打开帮助页。

动作的能力边界也必须明确：

- 可安全自动完成的动作（重试、打开本应用内某设置页）可以作为主按钮执行。
- 需要用户在 iPhone、Apple 账户或 LocalDevVPN 外部应用中完成的动作，只展示准确步骤，完成后由用户点“我已完成，重试”；Seal 不伪造成功。
- “复制诊断”永远可用，且包含 `diagnosticID`、稳定错误码、操作和脱敏原因；不包含静态帮助跳转。

### 5. 日志导出

日志导出分别表达：日志服务未注入、写入失败、分享文件无效。`SealLogStore.materializeExport()` 仍是唯一写入出口。运行时若仍报告“文件不存在”，错误记录必须包含构建标识、导出 URL 是否生成、写入错误；不得改写成存储空间或网络问题。

空日志属于正常业务结果：仍生成一个 UTF-8、可分享、包含生成时间和“暂无运行日志”的文件，不能被归类为失败。

### 7. 治理、兼容与可观测性

- 建立唯一的失败目录源（Swift 类型/注册表），CI 解析该源并校验：错误码唯一、每个确定性条件都有动作、路由合法、测试覆盖、无 UI 前缀推断。JSON、脚本、帮助页不再作为真相来源。
- 分类器为每个结果写结构化本地日志：`diagnosticID`、版本/构建号、operation、origin、condition、code、retryDisposition、脱敏根因。日志既能给用户导出，也能让维护者复盘。
- 新失败条件的变更必须同时包含：领域定义、分类测试、呈现测试、用户动作文案、`DEBUG_LOG.md` 记录；影响签名/续签时同步更新 `docs/upstream-alignment.md`。
- 旧错误码和历史日志只读兼容：旧码仍能显示原始诊断与“复制诊断”，但不会再被旧静态知识库或字符串规则重新解释。
- 上线后以 `diagnosticID` 作为用户反馈的最小凭据；只有在同一稳定码持续出现时，才允许基于证据新增更精确的条件或动作。

### 6. 分批实施

第一批覆盖合同类型、失败目录、Apple/Portal/证书/App ID/描述文件与单项/批量一致化；第二批覆盖设备/安装、导入/存储/日志导出，随后删除旧帮助链。每批都需要对应的单元测试和源码守卫；两批合并前不得有新旧 UI 同时暴露。

迁移采用“先合同与测试、再调用方、最后删除旧链”的顺序。任意时刻同一个失败只能由一个呈现路径处理；这是避免旧/新文案闪烁、抽屉重复弹出或动作不一致的发布门禁。

## 验收

1. 对同一个 `URLError.timedOut`，单项签名、单项续签、批量续签都给出相同的“检查可访问 Apple 开发者服务的网络后重试”操作，且不标记账号失效。
2. `SEAL-PROFILE-337` 在任一入口都给出“执行完整重签”。
3. 配对、信任、隧道端口、设备存储、iOS 拒绝、安装超时的操作分别可测试，且不会被路由到错误的设置页。
4. 所有旧帮助页面、静态资源、导航入口、脚本和测试均不存在。
5. 空日志也能导出一个有效日志文件；日志服务缺失、写入失败、分享文件无效三种失败可区分。
6. 全仓错误码扫描使用唯一解析器；扫描结果、代码定义与测试一致。
7. 每条用户可见失败都能回溯到 operation、origin、稳定 code 与 `diagnosticID`，且诊断不泄露账户、设备或认证数据。
8. CI 阻止新增的 `hasPrefix("SEAL-")`、`contains("SEAL-")` UI 路由与未登记错误码；所有分类优先级均由测试覆盖。
