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
| `SEAL-SIGN-503` | 单应用签名 / 续签撞上**设备通道瞬时失败**，已按批量同源策略退避重试（8 秒 × 第几次）—— **警告级**。看到它说明这一轮通道抖过；没有它时「本该重试却没有重试」在日志上完全看不出来 | `AppsViewModel.swift` |
| `SEAL-SIGN-504` | 单应用续签时**设备通道不可用**，自动重试后仍未恢复（底层多为 `Minimuxer.MinimuxerError 1` 的 `NoConnection`）。失败弹窗的「恢复」按钮据此跳 LocalDevVPN 设置页 | `AppsViewModel.swift` |
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
| `SEAL-VPN-003` | 观测到**本地隧道掉线**（`broken pipe` / `connection reset` / `early eof` 这类传输层对端消失），已作废 Swift 侧通道会话缓存、下一次操作重建连接 —— **警告级**。看到它说明这一轮撞上了掉线；没有它时「重试三次都撞同一个死会话」在日志上完全看不出来 | `MinimuxerInstallChannel.swift` |
| `SEAL-VPN-004` | **RemotePairing 端口自愈**：通道诊断 / 安装失败像是「隧道通、设备服务端口不可达」（`SEAL-INSTALL-710` 或 `connection refused` / `no route to host` / `connection timed out` 原文）时，经 Bonjour 重查 `_remotepairing._tcp` 端口，**发现到不同端口才采纳**（同步给 Rust 侧并作废按旧端口建的 RSD 缓存）—— **警告级**。看到它说明设备把服务换到了别的端口；没有它时「隧道明明通、就是连不上」在日志上完全看不出来 | `MinimuxerInstallChannel.swift` |

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
| `SEAL-RENEW-503` | 批量续签某一项撞上**设备通道瞬时失败 / 临时错误**，已退避重试（通道类 8 秒 × 第几次）—— **警告级**。重试前会走与单签同源的通道恢复动作（`SigningCoordinator.prepareInstallChannelForRetry`，通道类 `reset()`、描述文件超时类只清熔断）。看到它说明这一轮通道抖过；没有它时「批量重试了没有 / 重试了几次」在日志上完全看不出来 | `RenewalCoordinator.swift` |
| `SEAL-PROFILE-363` | `profile-only`（只换描述文件）的设备端身份核验**没有确认**（带原因：记录缺字段 / 设备端没有该身份 / 设备端枚举不可用）。⚠️ **2026-09-26 起它只是诊断信号，不再回落完整重签** —— 按上游 SideStore 的做法继续只更新描述文件，由注入后的逐份读回（`SEAL-PROFILE-354`）兜底。出现它意味着记录与设备现实可能有偏差，但**仍会成功** —— 不是失败 | `SigningCoordinator.swift` |
| `SEAL-PROFILE-364` | **本机没有该应用当前证书的私钥**（重装 Seal 清了 Keychain / 删过 Apple ID / 证书刚轮换）⇒ 本次**改为完整重签并安装**，重签后证书与本机匹配，后续续签会回到「只更新描述文件」。它是**降级而非失败**：出现它说明这一次会重装，但会成功。级别是 `警告` | `SigningCoordinator.swift` |
| `SEAL-PROFILE-365` | **记录里有一条「已导入但尚未安装」的更新源**（覆盖更新把记录写成了新导入包的版本号）⇒ 本次**改为完整重签并安装**，装完新版本才真正生效，之后续签回到「只更新描述文件」。它是**降级而非失败**。看到它说明「已安装列表里显示的版本号」是**待安装的源包**、不是正在运行的版本（用户 2026-09-26 实测：导入 1.3.20 到 1.3.19，点续签「直接续签了」而「关于」里仍是 1.3.19）。级别是 `警告` | `SigningCoordinator.swift` |
| `SEAL-PROFILE-352` | 注入描述文件超过 30 秒未返回 —— **警告级**。会置「污染」标记：下一次注入前自动重置并重建设备通道（见 `SEAL-PROFILE-355`），并纳入续签重试 | `ProfileOnlyProvisioningProfileInstaller.swift` |
| `SEAL-PROFILE-353` | 设备端读回描述文件超过 30 秒未完成 —— **警告级**。同样置污染标记 | `ProfileOnlyProvisioningProfileInstaller.swift` |
| `SEAL-PROFILE-354` | 注入报成功但设备端**读不回**该描述文件 ⇒ 本地到期日未更新（终态失败，不重试） | `ProfileOnlyProvisioningProfileInstaller.swift` |
| `SEAL-PROFILE-355` | 上一次描述文件设备操作超时留下的传输可能仍被占用，**已重置并重新建立设备通道后继续** —— **警告级**。看到它说明刚自愈过一次通道抖动；没有它时「一次超时毒掉后续**全部**续签」在日志上完全看不出来 | `SigningCoordinator.swift` |

## 后台保活 / 后台续签

> 这一整条链路在后台跑，**界面上什么都看不到** ⇒ 日志是唯一的证据。用户报「快捷指令触发了但没反应」
> 时按这个顺序看：
> ① `-006` 说明**触发了**，`-001` 说明**保活起来了**；
> ② `-007` / `-008` / `-009` 说明**点火前等通道**的结果 —— `-008` 带等待秒数（≈0 = 通道本来就好的），
>    `-009` 表示**通道没就绪但仍点了火**，这一轮很可能失败；
> ③ 两者都在却仍没续完 ⇒ 去看续签自己的码（「批量续签」一节）。
>
> ⚠️ **2026-09-26 构建 53 真机实证的组合**：`-006` ＋ `-001` 都在（触发链路是通的），
> 但两项续签都以 `Minimuxer.MinimuxerError 1`（`NoConnection`）失败，
> 且同一构建几分钟前的**前台**续签 2/2 成功 ⇒ 问题在**通道时序**，不在签名。
> 那次日志里没有 `-007/-008/-009`（那时还没这三个码），只能靠
> `SEAL-PROFILE-363` 的 `fallbackReason`（「设备端描述文件枚举不可用（通道未就绪或解析失败）」）反推。

| 码 | 它在说什么 | 出处 |
|---|---|---|
| `SEAL-BACKGROUND-001` | 后台保活已启动（静音音频无限循环）—— **信息级**，正常留痕 | `BackgroundKeepAliveService.swift` |
| `SEAL-BACKGROUND-002` | 后台保活**启动失败**（带底层原因）—— **警告级**。不打开 App 的续签会被系统挂起，只能在前台完成；这条出现说明「后台自动续签」这条链路只剩触发、没有保活 | `BackgroundKeepAliveService.swift` |
| `SEAL-BACKGROUND-003` | 后台保活已从音频中断（来电 / 闹钟）中恢复 —— **信息级** | `BackgroundKeepAliveService.swift` |
| `SEAL-BACKGROUND-004` | 后台保活**恢复失败**（带底层原因）—— **警告级**。下一次切后台起 Seal 会被挂起 | `BackgroundKeepAliveService.swift` |
| `SEAL-BACKGROUND-006` | 快捷指令 / App Intent 在**后台**触发了「续签全部应用」（未打开 App）—— 用来回答「这次续签是谁触发的」 | `AppsViewModel.swift` |
| `SEAL-BACKGROUND-007` | 后台触发**先等设备通道就绪再点火** —— **信息级**。快捷指令触发走的是**冷启动的新进程**，通道可能还在起步；点火前用强判据（`installChannel.start()`：reset + RSD 握手 + 轮询）等它 | `AppsViewModel.swift` |
| `SEAL-BACKGROUND-008` | 后台触发：设备通道**已就绪**（带等待秒数）—— **信息级**。秒数≈0 说明通道本来就好的（命中 900 秒成功缓存）；秒数很大说明这次是冷启动 | `AppsViewModel.swift` |
| `SEAL-BACKGROUND-009` | 后台触发：设备通道**未就绪**（带原因与等待秒数），**仍照常点火** —— **警告级**。看到这条说明这一轮很可能失败；失败项会按「通道瞬时错误」（`MinimuxerError` 的 `NoDevice` / `NoConnection`）自动重试 | `AppsViewModel.swift` |
| `SEAL-BACKGROUND-010` | 后台保活已从**音频路由变更**（插拔耳机 / 连断蓝牙）中恢复 —— **信息级**。上游 SideStore 不处理路由变更；这条出现说明 Seal 的自愈生效了（用户报的「听歌 / 看电视时续签不成功」正是缺了它） | `BackgroundKeepAliveService.swift` |
| `SEAL-BACKGROUND-011` | 后台保活**恢复失败**（音频路由变更后，带底层原因）—— **警告级**。下一次切后台起 Seal 会被挂起 | `BackgroundKeepAliveService.swift` |
| `SEAL-BACKGROUND-012` | 后台保活已从**媒体服务重置**中恢复（媒体守护进程崩溃重启，**重建播放器**）—— **信息级**。旧 `AVAudioPlayer` 已作废，只 `play()` 不够 | `BackgroundKeepAliveService.swift` |
| `SEAL-BACKGROUND-013` | 后台保活**恢复失败**（媒体服务重置后，带底层原因）—— **警告级**。下一次切后台起 Seal 会被挂起 | `BackgroundKeepAliveService.swift` |
| `SEAL-BACKGROUND-014` | 后台触发**让位**：已有签名 / 续签（或导入配对、管理证书等占着通道的操作）尚未完成，本轮**不重复点火** —— **信息级**。看到它说明「快捷指令这一轮没续上」不是失败，而是进行中的那一轮会完成续签；没有这条日志时，「没续上」与「其实被让位」在日志上长得一模一样 | `AppsViewModel.swift` |
| `SEAL-BACKGROUND-015` | 快捷指令后台续签**系统通知**的投递结果（已发出 / 本轮无可续签项按规则不发 / 用户未开通知权限 / 投递失败带原因）—— **信息级**（未发出为警告级）。用户报「快捷指令续签成功但没收到通知」时，先用这条分清「其实没给通知权限」与「真的投递失败」 | `AppsViewModel.swift` |
| `SEAL-BACKGROUND-016` | 快捷指令后台续签**未执行 / 整轮失败**通知的投递结果（让位给非续签操作 / 取操作锁等满 30 秒 / 整轮抛错）—— **信息级**（未发出为警告级）。这三档**没有任何一轮会补上**，后台又没有界面，不发就是静默丢失；看到它可分清「用户点了快捷指令却什么都没发生」到底是哪一档 | `AppsViewModel.swift` |
| `SEAL-BACKGROUND-017` | 后台保活**第二路（后台定位）已启动**：持续定位更新，与静音音频形成双保险 —— **信息级**。音频被打断（来电/闹钟/路由变更/媒体重置）时，定位兜底让进程不被系统挂起；看到它说明双保险到位，锁屏续签多了一层存活保障 | `LocationKeepAliveService.swift` |
| `SEAL-BACKGROUND-018` | 后台保活**第二路（后台定位）无法启动**：定位权限被拒绝/受管控 —— **警告级**。此时只剩静音音频一路保活，音频被中断时锁屏续签可能被系统挂起；可作为「音频一路而已」的判据，区别于「双保险」 | `LocationKeepAliveService.swift` |

## 操作仲裁

| 码 | 它在说什么 | 出处 |
|---|---|---|
| `SEAL-OP-001` | 暂时无法执行：另一项操作（导入 / 签名 / 安装 / 续签 / 证书 / 配对…）正在进行，为避免状态互相覆盖已阻止本次操作 —— 等它完成后重试 | `OperationCoordinator.swift` |
| `SEAL-OP-002` | 已有操作在进行：用户点的「续签全部」/「签名」被另一项**未完成**的操作挡住（**也可能是快捷指令在后台触发的自动续签**）—— 明确说出被谁挡住，不再静默丢弃 | `AppsViewModel.swift` |

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

## 钥匙串可访问性

> 背景：锁屏下用**快捷指令**续签（`openAppWhenRun = false`，进程在锁屏时冷启动）时，
> 每次都要**现读**钥匙串（账号密钥 + anisette）。条目若还是 `WhenUnlockedThisDeviceOnly`
> 就**读不到** ⇒ 抛 `Seal.KeychainError` ⇒ 续签直接失败。真机日志一度只剩一句
> `Seal.KeychainError 1`（OSStatus 被 NSError 桥接丢掉），看起来像「钥匙串里没有」，
> 其实是**设备锁定**。修复 = 写入改用「首次解锁后可读」＋ 把升级前的旧条目**一次性迁移**过去。

| 码 | 它在说什么 | 出处 |
|---|---|---|
| `SEAL-KEYCHAIN-001` | 钥匙串可访问性**已迁移**为「首次解锁后可读」，锁屏下的后台续签可正常读取账号密钥与 anisette —— **信息级**，只在真的改过条目时记一次 | `KeychainAccessibility.swift` |
| `SEAL-KEYCHAIN-002` | 迁移时**设备仍锁定**，本次未完成（`errSecInteractionNotAllowed`）—— **警告级**。不是失败：解锁后打开 Seal 会自动补迁；若用户始终不解锁，锁屏续签仍会失败 | `KeychainAccessibility.swift` |
| `SEAL-KEYCHAIN-003` | 迁移**失败**（带各 service 的归类结果）—— **警告级**。下次启动重试；这条说明修复没能生效，锁屏续签会继续失败 | `KeychainAccessibility.swift` |

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
| `SEAL-PROFILE-350` | 描述文件注入的**安全网**（调用方未先解除污染就想注入）。**2026-10-04 并行续签后已移除**：actor 拿锁后自愈污染（消费 + 重置 + 注入原子完成），不再抛错 |
| `SEAL-PROFILE-351` | 「另一项续签仍在使用设备通道」错误。**2026-10-04 并行续签后已移除**：改为 task-chain 排队等待，不再直接抛错（`misagent` 仍是同一时间只有一项在写） |
