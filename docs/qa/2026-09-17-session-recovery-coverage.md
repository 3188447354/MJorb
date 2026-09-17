# 「遇 1100 就退避重试」这条规则漏在了两条链路上

- 日期：2026-09-17
- 触发：排查「只有抖音签不上」时，顺着「为什么抖音特别容易撞限流」去**枚举门户写入**
- 相关日志码：`SEAL-AUTH-107`、`SEAL-CERT-227`
- 同族文档：[`2026-09-17-app-id-order-and-quota-diagnostic.md`](./2026-09-17-app-id-order-and-quota-diagnostic.md)（抖音那条线索的完整记录）

## 现象

没有真机现象 —— 这两处是**审计出来的**。它们的共同点是：

> 错了**不崩、不编译失败、守卫全绿**，只在真机上把「限流」当成事实处理。

## 怎么找到的

不要靠回忆「我加过哪些链路」，而是**枚举这一类操作**：

```bash
grep -n "ALTAppleAPI.shared\." Seal/Infrastructure/Signing/ApplePortalSigningService.swift
```

14 个调用点里 9 个是**写入**，再逐个问两个问题：

1. **它在不在 per-bundle-ID 循环里？**（在 ⇒ 构成突发 ⇒ 会被限流）
2. **它有没有过 `withSessionRecovery`？**

| 原语 | 位置 | 在循环里？ | 有退避重试？ |
|---|---|---|---|
| `addAppID` | Phase 1 | 是（抖音 **9 次**） | ✅ |
| `update`（`updateFeatures` → `submitUpdatedAppID`） | Phase 1 | **是（9 次）** | ❌ → 本次补 |
| `fetchProvisioningProfile`（内部还会 delete） | Phase 2 | 是（9 次） | ✅ |
| `addCertificate` | 证书阶段 | 否（1 次） | ✅ |
| `addAppGroup` / `assign` / `fetchAppGroups` | `assignAppGroups` | 是（付费账号，每 ID 最多 3 次） | ❌ → 本次补 |
| `registerDevice` / `revoke` | 一次性 | 否 | 刻意不覆盖 |

⇒ Phase 1 每个 bundle ID 实际要发 **2 次**写请求，抖音一次签名是 **18 次**突发，
其中**一半**（9 次 `updateFeatures`）完全没有保护。

另一条链路（另一个文件）：

| 服务 | 路径 | `addCertificate` 有退避重试？ |
|---|---|---|
| `ApplePortalSigningService` | **签名** | ✅ |
| `ApplePortalCertificateService` | **证书轮换 / 孤儿证书清理** | ❌ → 本次补 |

## 为什么漏了却一直没被发现

守卫 R24 的断言是：

```python
check(portal_source.count("withSessionRecovery(") == 3, ...)
```

**那个 `3` 是从当时的代码里数出来的**，不是从设计推出来的 ——
于是它把「覆盖不全」**固化成了期望值**。而 R24 当轮补的是「创建证书」，
`updateFeatures` 从来没有被纳入过「portal 变更」这个清单。

同类问题在守卫里还有第二种形态：**只对一条链路做断言**。
`portal_source` 只是 `ApplePortalSigningService.swift` 一个文件，
所以另一个文件里的 `addCertificate` 漏了，守卫**结构上就看不到**。

## 漏掉的后果（都不报错，这是它值钱的地方）

### `updateFeatures`（Phase 1，抖音 9 次）

1. **主 App** 撞 1100 ⇒ 落到 `guard mappedBundleID != mappedMainBundleID else { throw error }`
   ⇒ **整个签名失败**，用户看到的只是「Apple ID 失效」；
2. **扩展** 撞 1100 ⇒ 走 `catch where mappedBundleID != mappedMainBundleID` 的降级分支，
   把 `requestedEntitlements[mappedBundleID] = [:]` **清空**后继续签
   ⇒ 签名「成功」，但扩展在真机上缺权限（**静默降级比失败更难查**）。

### `ApplePortalCertificateService.addCertificate`（证书轮换）

**这个结论不是从 `MEMORY.md` 抄的，是去代码里读出来的**（写「后果有多严重」这类结论前必须读一遍那条路径）。
有两条链路确实是「先 revoke、再创建」，而且都用 `ApplePortalCertificateService`：

**① `SettingsViewModel.revokeCertificateAndCreateLocal`（622 行起）**

| 行 | 动作 |
|---|---|
| 688 | `revokeCertificate(serialNumber:)` —— **撤销旧证书** |
| 696–712 | 拉清单确认槽位已释放（确认不了就不创建） |
| 716–724 | 把本地 keychain 里那张证书的 `certificateP12` / `certificateSerialNumber` **清空** |
| **726** | `createLocalCertificate(...)` —— **创建新证书** |
| 748–751 | 失败 ⇒ `alertFailure`（**用户能看到**，不是静默） |

**② `SettingsViewModel.executeCertificateCleanup`** —— 944 撤销 → 980 创建，同一形态。

⇒ 创建这一步失败（1100 被当成真过期、直接抛）时：**旧证书已撤销、本地凭据已清空、新证书没建成**
⇒ 这个账号变成 **0 张可用证书**，而撤销时 `affectedInstalledApps` 里的 App 已经失去签名依据
（`AppsViewModel:1062-1071` 在「一键全撤」后立刻 `restartSigning`，并把这些 App 记进
`certificateSacrificeResignQueue`；签名若没成功，队列会被清空、只剩一条日志引导手动续签）。

⇒ **`updateFeatures` 那条是「静默降级」，这条是「账号被清空」** —— 严重性不在一个量级，
所以这条即使只在设置页触发也必须补。

## 修复

### 1. 补上两处调用点

```swift
// ApplePortalSigningService（Phase 1）
let updatedAppID: ALTAppID =
    try await withSessionRecovery("更新应用能力 \(mappedBundleID)") {
        try await updateFeatures(appID: appID, application: application, team: team, session: session)
    }
appID = updatedAppID
if team.type != .free {
    try await withSessionRecovery("分配 App Group \(mappedBundleID)") {
        try await assignAppGroups(appID: appID, application: application, team: team, session: session)
    }
}

// ApplePortalCertificateService（证书轮换）
requested = try await withSessionRecovery("创建证书（证书轮换）") {
    try await addCertificate(team: context.team, session: context.session, deviceName: deviceName)
}
```

### 2. 判据与间隔**共用一份**，不抄

`ApplePortalCertificateService` 的 `withSessionRecovery` 刻意只复用
`ApplePortalSigningService` 的两个成员：

- `ApplePortalSigningService.isSessionExpiredError(error)` —— **哪些错误值得重试**；
- `ApplePortalSigningService.sessionRecoveryBackoffNanoseconds` —— **退避多久**
  （访问级别由 `private` 放开为 `internal`，就是为了这一处共用）。

这两项才是会漂移的东西。抄一份的话，同一个 1100 会在一条链路上重试、在另一条上直接失败。

### 3. 创建失败时的文案（R30）

补了退避重试之后还有一个问题：**重试耗尽时用户看到的是什么？**

原先 1100 会**原样上抛**（`CertificateRequestFailurePolicy.requestFailure` 对它返回 `nil`），
落到调用方的通用 `catch`，变成：

> 无法完成证书处理 / 已按用户选择处理证书，但 Apple 或本地保存阶段**没有返回明确失败原因**。  
> recovery：重新同步证书后确认当前状态

三处都不对：

1. **「没有返回明确失败原因」是假的** —— 原因就是 Apple 返回的 1100；
2. **没说清这是限流**（不是登录真的失效）⇒ 用户可能跑去重新验证 Apple ID；
3. **最要紧的：没说「旧证书已经撤销、这个账号现在可能没有可用证书」** ⇒
   用户不知道该立刻重新创建一张。

改成专门的 `SEAL-CERT-233`：

> **新证书没有创建成功** / Apple 拒绝了本次创建证书的请求（返回「会话已过期」）。这通常是短时间内请求过密触发的限制，不代表登录真的失效 —— 退避重试已经试过几次才放弃。  
> ⚠️ 若你刚才是在「撤销并创建新证书」或证书清理，请注意撤销**已经生效**：这个账号现在可能没有可用证书，已装 App 需要重新签名才能续期。  
> recovery：先等几分钟再重试创建；若仍失败，到「我的」重新验证这个 Apple ID 后再创建一张证书

⚠️ 文案刻意用「**若你刚才是在…**」而**不假设「一定发生了撤销」** ——
设置页的「创建证书」按钮走的是同一个 `createLocalCertificate`，那时没有任何撤销，
写「撤销已生效」就是新的误导。守卫 R30 同时钉住这两件事（必须写明后果 + 不许假设撤销）。

### 4. 已知的可观测性缺口（未修，已记档）

`ApplePortalCertificateService` **没有 `logStore`**，所以它的重试**不写日志**。
之所以还能接受：重试成功时结果本身可见；重试耗尽时错误照旧上抛，
会变成 `SEAL-CERT-227`「证书轮换失败」提示（已写明后果）。
要补日志得给它注入 `SealLogStore`（三个构造点都拿得到），属另一轮改动。

## 守卫改造

- **R24 重写**：从「数个数」改成「**按操作逐个点名**」（5 个 label + 1 个计数兜底），
  并把「刻意不覆盖 `revoke` / `registerDevice` / `fetch*`」的**理由**写进守卫 ——
  「不在循环里、不构成突发」这个判断本身也是设计的一部分。
- **R29 新增**：断言证书轮换路径的 `addCertificate` 也过退避重试，
  且**共用**签名服务那一份判据与间隔。
- 变异锚点 +4（`updateFeatures` 退回直接请求 / `assignAppGroups` 退回 / 轮换的
  `addCertificate` 退回 / 在新链路里抄一份自己的判据）。

**规模：354 源码断言 + 192 变异 PASS。**

## 验证状态

- 静态守卫：PASS
- 云构建：run#115（`updateFeatures` 那批）全绿（首跑 UI 测试抖动，重跑绿）
- 真机：待验

## 待真机确认的判据

日志里应能看到（run#115 起）：

```
Apple 会话疑似被限流，退避 2 秒后重试 创建 App ID com.xxx
Apple 会话疑似被限流，退避 4 秒后重试 更新应用能力 com.xxx
```

- **看到退避行** ⇒ 限流确实发生了，且退避重试正在工作 —— 耐心等，不要手动重试（会叠加密度）。
- **看不到退避行却仍失败** ⇒ 不是限流，去看 `App ID 名额：… 需新注册 K 个` 那条。
- ⚠️ 最坏情况会等比较久：抖音 18 次写请求 × 每次最多退避 3 轮（1.5+4+8 秒）
  ⇒ 理论上可能多等几分钟，界面会一直停在「正在准备 App ID」。**这是有界的，不是卡死。**
