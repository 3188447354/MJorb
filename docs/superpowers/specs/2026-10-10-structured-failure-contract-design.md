# Seal 结构化失败合同设计

## 目标

让签名、单项续签、批量续签、安装、导入、日志导出对同一根因展示同一条可执行操作；移除旧“错误帮助”页面、静态知识库和基于错误码前缀的猜测式路由。

## 不变约束

- 运行日志继续保存稳定错误码及脱敏诊断，历史日志仍可阅读。
- Apple Portal、设备通道、描述文件、证书和签名包不能被同一句“检查 Wi-Fi/LocalDevVPN”覆盖。
- profile-only 续签找不到 App ID（`SEAL-PROFILE-337`）必须引导完整重签，不能提示网络或重新验证账号。
- 设备配对、设备信任、隧道端口、设备存储、iOS 拒绝、安装超时必须保持独立语义。
- 签名/续签语义继续对齐现有 SideStore 对照结论：profile-only 不创建 App ID，完整重签才重建身份。

## 设计

### 1. 失败合同

`ImportFailure` 不再只是四段文案。它新增结构化字段：

- `condition`：源码已经确认的事实，例如 `appleServiceUnavailable`、`appleRateLimited`、`credentialsRejected`、`verificationCodeRejected`、`fullResignRequired`、`pairingRequired`、`deviceTrustRequired`、`tunnelUnavailable`、`deviceStorageFull`、`installationStillRunning`、`signedArtifactInvalid`、`localStorageWriteFailed`、`logServiceUnavailable`、`unexpected`。
- `action`：唯一用户动作，例如 `retry`、`waitThenRetry`、`reauthenticateAccount`、`enterNewVerificationCode`、`fullResign`、`repairPairing`、`trustDevice`、`openLocalDevVPN`、`freeDeviceStorage`、`checkInstallationResult`、`reinstallFromSignedArtifact`、`reimportIPA`、`restartSeal`、`copyDiagnostics`。
- `route`：可选设置页目标，只有动作确实需要跳转才赋值；不从错误码字符串推断。
- `retryDisposition`：`none`、`automatic`、`manual`、`waitForInFlightWork`。

`title`、`reason`、`recovery`、`code` 继续保留，以维持日志、SwiftUI 和历史记录兼容；UI 文案只由结构化动作生成，不再让调用方按 code 改写文字。

### 2. 分类只发生在错误边界

新增一个纯函数分类器，输入原始 `Error` 加上操作上下文（Apple 认证、Portal、签名、设备通道、安装、导入、日志），输出一个完整 `ImportFailure`。

- Apple 超时/限流/凭据/验证码/Anisette 各自归类；`URLError.timedOut` 不能再落进 `SEAL-SIGN-500`。
- `SEAL-PROFILE-331...337`、证书缺私钥、签名包缺失/损坏等已是确定性业务错误，原样透传并附上明确动作。
- `MinimuxerInstallChannel` 保留现有的细分诊断；它将诊断映射成结构化条件，而非在每个错误文案里堆叠 Wi-Fi、VPN、解锁等猜测。
- 真正无法分类的错误才得到 `unexpected + copyDiagnostics`；日志记录域、码和脱敏诊断，但 UI 不假装知道原因。

### 3. 单一呈现路径

`AppsViewModel`、`RenewalCoordinator`、`SigningCoordinator`、`SettingsViewModel` 只能透传或调用分类器，禁止重新用 `hasPrefix`、`contains` 或固定 500 文案解释失败。

- 单项签名、单项续签、批量续签、缓存签名包安装共用同一失败合同。
- 批量重试只读取 `retryDisposition`；不再把所有未包装错误改写为 `SEAL-RENEW-500`。
- 按钮标题、动作、设置页路由只读取 `action` 与 `route`。

### 4. 删除旧帮助链

删除 `ErrorHelpView`、`ErrorKnowledgeStore`、`help-index.json`、相关测试、错误目录生成和 CI 校验；删除设置项和所有“查看解决办法”次级弹层。

失败弹层直接显示：简短事实说明、一枚与 `action` 对应的主按钮；无法自动操作时仅显示“复制诊断”。日志页保留复制错误信息，不再打开帮助页。

### 5. 日志导出

日志导出分别表达：日志服务未注入、写入失败、分享文件无效。`SealLogStore.materializeExport()` 仍是唯一写入出口。运行时若仍报告“文件不存在”，错误记录必须包含构建标识、导出 URL 是否生成、写入错误；不得改写成存储空间或网络问题。

### 6. 分批实施

第一批覆盖合同类型、Apple/Portal/证书/App ID/描述文件与单项/批量一致化；第二批覆盖设备/安装、导入/存储/日志导出，随后删除旧帮助链。每批都需要对应的单元测试和源码守卫；两批合并前不得有新旧 UI 同时暴露。

## 验收

1. 对同一个 `URLError.timedOut`，单项签名、单项续签、批量续签都给出相同的“检查可访问 Apple 开发者服务的网络后重试”操作，且不标记账号失效。
2. `SEAL-PROFILE-337` 在任一入口都给出“执行完整重签”。
3. 配对、信任、隧道端口、设备存储、iOS 拒绝、安装超时的操作分别可测试，且不会被路由到错误的设置页。
4. 所有旧帮助页面、静态资源、导航入口、脚本和测试均不存在。
5. 空日志也能导出一个有效日志文件；日志服务缺失、写入失败、分享文件无效三种失败可区分。
6. 全仓错误码扫描使用唯一解析器；扫描结果、代码定义与测试一致。
