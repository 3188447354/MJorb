# 日志码索引（真机日志里实际出现过的）

> **用途**：用户发来一份日志时，先用它把 `[SEAL-XXX-NNN]` 翻译成人话，
> 不用每次去 grep 源码。**完整码表有 300+ 个**（见 `Seal/**/*.swift` 里的 `code:`），
> 这里只收**真机日志里实际出现过**的那些。
>
> ⚠️ **本文件由脚本从源码抽取**（`code:` 往前找最近的调用起点，取其中的 `message:`/`title:`/`reason:`）。
> 守卫断言「本文件里的每个码在源码里仍然存在」—— 防的是**码被删掉、文档却还留着**这种情况
> （2026-09-17 实测踩到：`SEAL-APPID-305` 是刻意去掉的本地硬拦、`SEAL-CERT-224` 已不存在，
> 而旧日志里还留着它们，容易误判成「现在还在报」）。

## 怎么用

1. **先定版**（回归清单第 0 步）：没有 `构建 1.1.16 (N)` 表头 ⇒ 日志太旧，别分析。
2. 在下面查码 → 得到「它在说什么」。
3. **级别比码更重要**：`错误` 才需要处理；`警告` 多半是「降级但仍继续」；`信息` 是正常留痕。
4. 若某个码不在表里 ⇒ 说明它**从没在你的日志里出现过**，可以照常 grep 源码。

## 账号 / 登录

| 码 | 它在说什么 | 出处 |
|---|---|---|
| `SEAL-ANI-115` | Apple 拒绝了本次认证用的设备环境数据（Anisette） | `AppleAccountClient.swift` |
| `SEAL-AUTH-102a` | Apple 拒绝了该账号的登录凭据 | `AppleAccountClient.swift` |
| `SEAL-AUTH-102c` | **账号需要重新验证**（Apple 返回「认证状态无效」）⇒ 去「我的」重新登录 | `ApplePortalSigningService.swift` |
| `SEAL-AUTH-105a` | 本机 Keychain 里缺少该 Apple ID 的登录凭据（**重装 Seal 会清空 Keychain**） | `SigningCoordinator.swift` |
| `SEAL-AUTH-107` | **登录过期了**（1100 会话过期）—— 该码在账户阶段与 App ID 阶段**文案不同**，见源码 | `AppleAccountClient.swift` 等多处 |
| `SEAL-AUTH-107a` | Apple ID 验证失败（带诊断信息） | `AppleAccountClient.swift` |
| `SEAL-VERIFY-500` | Apple 验证返回了**无法分类**的错误；账号状态未改变 | `SettingsViewModel.swift` |

## 证书

| 码 | 它在说什么 | 出处 |
|---|---|---|
| `SEAL-CERT-204b` | 无法生成有效证书请求，或 Apple 拒绝了请求（**不代表名额已满**） | `CertificateRequestFailurePolicy.swift` |
| `SEAL-SIGN-501` | Apple 暂时拒绝了请求（App ID 阶段撞限流；**先等几分钟重试**） | `ApplePortalSigningService.swift` |
| `SEAL-APPID-303` | App ID 创建失败（Apple 未创建；常见原因见同行的 `Apple 返回：`） | `ApplePortalSigningService.swift` |
| `SEAL-EXT-401` | **扩展**无法创建 App ID（多扩展 App 会走到这条） | `ApplePortalSigningService.swift` |

## 安装 / 设备通道

| 码 | 它在说什么 | 出处 |
|---|---|---|
| `SEAL-INSTALL-701` | 本地隧道未就绪，无法连接设备（确认 Wi-Fi + LocalDevVPN 已连接） | `MinimuxerInstallChannel.swift` |
| `SEAL-INSTALL-702l` | iOS 拒绝了安装：**免费账号已装 3 个自签应用**或签名校验失败 | `MinimuxerInstallChannel.swift` |
| `SEAL-INSTALL-702s` | 设备**空间不足**（解压复制阶段） | `MinimuxerInstallChannel.swift` |
| `SEAL-INSTALL-707` | 已安装页设备核验**未完成**（设备查询失败/超时），已保留当前列表、本轮未删除任何记录 | `AppsViewModel.swift` |
| `SEAL-INSTALL-708` | 已安装页设备核验**跳过**：有前台操作正在进行（避免抢占同一条设备会话） | `AppsViewModel.swift` |
| `SEAL-INSTALL-739` | 已安装页设备核验**中止**：阳性对照未通过（通道不可信），本轮一条记录都不删 | `AppsViewModel.swift` |
| `SEAL-VPN-001` | 签名完成后仍无法连接设备完成安装 | `SigningCoordinator.swift` |

## 描述文件清理 / 维护

| 码 | 它在说什么 | 出处 |
|---|---|---|
| `SEAL-PROFILE-320` | 维护期清理摘要（`扫描/匹配/删除` + 旧 Team 变体计数）—— **唯一**覆盖全部管理 App | `AppMaintenanceJob.swift` |
| `SEAL-PROFILE-321` | 已清理 N 份设备端旧描述文件（有删才写） | `AppsViewModel.swift` |
| `SEAL-PROFILE-322` | 自替换结算清理摘要 —— **唯一**能回收 Seal 自己那份 | `SelfAppRegistrar.swift` |
| `SEAL-STORAGE-006` | 维护作业在「某阶段」被打断（用户操作开始），未执行的步骤已跳过 | `AppsViewModel.swift` |
| `SEAL-STORAGE-009` | 维护作业本轮**跳过**：有前台操作正在进行 | `AppsViewModel.swift` |

## 批量续签

| 码 | 它在说什么 | 出处 |
|---|---|---|
| `SEAL-RENEW-007` | 上次续签被中断，**N 个应用的结果未知**，需要重新核验（只有真没结论时才该出现） | `AppsViewModel.swift` |
| `SEAL-RENEW-011` | 用户取消批量续签（已处理 N/M） | `AppsViewModel.swift` |
| `SEAL-RENEW-020` | 逐项成功留痕（带描述文件 UUID + 创建/到期时间） | `RenewalCoordinator.swift` |
| `SEAL-RENEW-021` | 待恢复的批量续签结果**被跳过**（只该出现一次；反复出现说明判据退化） | `AppsViewModel.swift` |
| `SEAL-RENEW-023` | 批量续签结果已持久化（`.pushing`/`.installing` 会重复推送 ⇒ 可能写多次，正常） | `AppsViewModel.swift` |
| `SEAL-RENEW-024` | 批量续签结果已从持久化载荷恢复 | `AppsViewModel.swift` |
| `SEAL-RENEW-025` | 批量续签结果抽屉已关闭（带最终计数） | `AppsViewModel.swift` |
| `SEAL-RENEW-026` | 上次续签被中断，但 N 个应用的结果**已从载荷结算**（不再标为未知）—— 正常路径留痕 | `AppsViewModel.swift` |
| `SEAL-PROFILE-363` | `profile-only`（只换描述文件）的设备端身份核验**没有确认**（带原因：记录缺字段 / 设备端没有该身份 / 设备端枚举不可用）。⚠️ **2026-09-26 起它只是诊断信号，不再回落完整重签** —— 按上游 SideStore 的做法继续只更新描述文件，由注入后的逐份读回（`SEAL-PROFILE-354`）兜底。出现它意味着记录与设备现实可能有偏差，但**仍会成功** —— 不是失败 | `SigningCoordinator.swift` |
| `SEAL-PROFILE-364` | **本机没有该应用当前证书的私钥**（重装 Seal 清了 Keychain / 删过 Apple ID / 证书刚轮换）⇒ 本次**改为完整重签并安装**，重签后证书与本机匹配，后续续签会回到「只更新描述文件」。它是**降级而非失败**：出现它说明这一次会重装，但会成功。级别是 `警告` | `SigningCoordinator.swift` |

## 账号清单同步

| 码 | 它在说什么 | 出处 |
|---|---|---|
| `SEAL-INVENTORY-100` | App ID 清单同步时本机缺少该 Apple ID 的登录凭据 | `SettingsViewModel.swift` |
| `SEAL-INVENTORY-900` | App ID 清单同步失败（带 domain/code） | `SettingsViewModel.swift` |
| `SEAL-INVENTORY-100a` | 本机没有该 Apple ID 的登录凭据（同步前需要先验证） | `SettingsViewModel.swift` |
| `SEAL-INVENTORY-900a` | 证书状态同步失败（带 domain/code） | `SettingsViewModel.swift` |
| `SEAL-INVENTORY-100b` | Apple ID 总览完整同步时本机缺少该账号凭据 | `SettingsViewModel.swift` |
| `SEAL-INVENTORY-900b` | Apple ID 总览的 App ID 与证书状态同步失败（带 domain/code） | `SettingsViewModel.swift` |

## 设备配对

| 码 | 它在说什么 | 出处 |
|---|---|---|
| `SEAL-PAIR-209` | 未存有可导出的配对文件 | `PairingStore.swift` |
| `SEAL-PAIR-209a` | 本机配对文件读取或结构复核失败，无法导出 | `SettingsViewModel.swift` |

## 已从源码移除（旧日志里还会看到，**别当成现在还在报**）

> ⚠️ **本表的表格行里不要再出现任何「反引号包裹、且仍在源码中」的码** —— 守卫 R22 会把
> 「已移除」表里所有 `` `SEAL-XXX-NNN` `` 当成**移除清单**，命中仍在源码的码就报
> 「又回到源码里了」。要在说明里提到新码，就写成**不带反引号的纯文本**，或只写「见主表某节」。
> （2026-09-25 实际踩到：`SEAL-PROFILE-362` 那行写了新码 ⇒ R22 判 363「复活」。）

| 码 | 情况 |
|---|---|
| `SEAL-APPID-305` | 「`existing.count >= 10` 就硬拦」的本地预检，**已刻意去掉** —— Apple 的真实上限是「7 天内最多注册 10 个」（滑动窗口），本地一刀切会误拦 |
| `SEAL-CERT-224` | 源码里已不存在（历史码） |
| `SEAL-RECONCILE-001`、`SEAL-RECONCILE-003`、`SEAL-RECONCILE-005` | 旧的已安装列表对账日志；该对账实现已移除，旧日志仍可能出现这些码 |
| `SEAL-PROFILE-362` | 「无法在设备端确认描述文件身份」的**终态失败**，已删除 —— 改为**回落完整重签**（新码登记在主表「批量续签」一节）。旧行为把「无法核验」与「身份不符」折成同一条死路，通道抖动一次应用就永久续签不了（2026-09-25 构建 39 真机） |
