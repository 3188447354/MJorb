# Signed IPA 缓存与续签身份分层

## 目标

释放本地已签名 IPA 缓存不得改变 iPhone 已安装应用、Apple 证书私钥、设备端描述文件，或使原本合格的 profile-only 续签回退为完整重签。

## 现状与根因

`SettingsViewModel.clearStoredSignedPackages()` 目前逐条调用 `AppRecord.clearSignedArtifact()`，再删除 `Apps/<id>/Signed.ipa`。前者同时清掉签名包路径、SHA、大小、时间和 `signedArtifactStatus`。

但 `ProfileOnlyRenewalPolicy.evaluate(app:)` 把 `signedArtifactStatus == .installed` 与 `hasSignedArtifact` 当作 profile-only 的准入条件。`hasSignedArtifact` 又依赖本地 `Signed.ipa` 的路径与 SHA。因此，缓存清理会把第三方已安装应用错误降级为完整重签；第三方没有 Seal 自身可用的运行中包身份读取兜底。

## 领域分层

| 层 | 内容 | 生命周期 | 清理规则 |
| --- | --- | --- | --- |
| 源包 | `Original.ipa` | 用户导入至用户删除本地源包 | 维护页不清理 |
| 续签身份 | Team、证书序列号、UDID、映射 Bundle ID、描述文件绑定、目标权限 | 首签/续签成功后更新 | 缓存清理永不删除 |
| 安装缓存 | `Signed.ipa`、SHA、文件大小、修改时间 | 完整签名后生成，可随时重建 | 仅安全候选可删除 |
| 安装事务 | `pendingSignedSnapshot`、安装失败状态、待核验状态 | 事务开始到设备确认终态 | 未结算前保护缓存 |

## 行为契约

### Profile-only 续签

若已安装应用的续签身份完整、本机仍有对应私钥、设备与账号匹配且无待安装更新源，续签只申请并注入新的描述文件。它不读取、不生成、不安装 `Signed.ipa`。

若持久化目标权限齐全，Portal 准备使用已存的目标身份，亦不应因读取不到 `Original.ipa` 而失败；若旧记录缺失这些信息，才需要 `Original.ipa` 走解析兜底。维护页仍不提供删除源包的操作。

### 完整重签回退

仅在续签身份无法安全复用、证书私钥不可用、待安装更新源存在或其他既有快路径判据明确拒绝时：

`Original.ipa -> 完整签名 -> 新 Signed.ipa -> 覆盖安装设备上的 App`

删除缓存本身不是回退理由。

## 缓存清理策略

### 可清理

仅当记录已确认安装、没有待确认快照、没有安装失败待恢复状态、没有待安装更新源且不是 Seal 自替换事务时，`Signed.ipa` 是可清理缓存。

清理只删除实际文件与其缓存校验元数据；续签身份、安装确认状态、应用列表状态、原始 IPA 与账号密钥保持不变。

### 必须保留

- `awaitingVerification`
- `installFailed`
- 存在 `pendingSignedSnapshot`
- Seal 自替换尚未由新进程确认
- 已导入但尚未安装的新版本或同版本不同源包

### 导出副本与临时文件

`removeSignedIPA` 不得再顺带删除 `Exports/<appID>`。导出副本归入临时/导出文件的独立清理路径与独立统计，不能与签名安装缓存混为一项。

## 模型与模块设计

将 profile-only 准入从“签名缓存存在”拆离：

1. `ProfileOnlyRenewalPolicy` 只校验已安装状态与续签身份，不读取 `signedIPARelativePath`、缓存 SHA 或缓存状态。
2. 创建一个纯策略模块（例如 `SignedIPACacheCleanupPolicy`），输入 `AppRecord`，返回 `.reclaimable` 或带原因的 `.protected`；所有 UI、清理执行和测试都通过该模块判断。
3. 保留现有 `Signed.ipa` 元数据作为缓存信息，但不再让 `signedArtifactStatus` 承担“缓存存在”和“设备安装确认”两种含义。实施时新增明确的缓存存在状态，或将现有状态的设备确认职责迁移到独立安装确认状态，并为旧记录迁移。
4. 清理执行采用两阶段语义：先由策略得出候选及预估字节数；删除成功后只更新对应缓存状态。删除失败时记录状态保持可复用，不制造“文件仍在但记录说不存在”或反向不一致。

## 维护页

- “清理签名包”更名为“释放可重建安装缓存”。
- 仅在安全候选数量大于零且可释放空间大于零时显示按钮；没有可清理内容时不显示该按钮。
- 确认弹窗显示候选数量和预计释放空间，并明确不会删除手机应用、原始 IPA、证书私钥或设备端描述文件；不会影响 profile-only 续签。
- 临时缓存、未使用文件与导出副本保持独立按钮；没有候选的动作同样不显示。

## 测试与验收

先增加纯策略及续签准入回归测试：

1. 删除 `Signed.ipa` 缓存后，完整续签身份的第三方应用仍可进入 profile-only。
2. 清理候选排除全部未结算安装事务和待安装更新源。
3. 可清理稳定缓存被删除后，原始 IPA、续签身份和安装状态保持。
4. 缓存文件删除失败时，记录不应先被破坏。
5. `Exports` 不被签名缓存清理删除。
6. 无候选时维护页不呈现对应清理按钮。

CI 需通过完整 iOS 工作流；真机验收包含：清理前后一次 profile-only 续签，确认无上传/覆盖安装且设备端描述文件有效期更新。
