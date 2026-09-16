# 抖音（8 扩展）签名失败 + 通道熔断优化

日期：2026-09-16
输入：`Seal-log(2) (1).txt`（587 行，覆盖 2026-09-13 ~ 2026-09-16）
结论性质：**1 个真 bug（限流被误报为登录过期）+ 1 个文案 bug + 1 项结构性约束**

---

## 一、现象

> 签抖音 IPA 时，这个抖音有 8 个扩展，id 有足够的名额，但无论怎样在验证 Apple ID 就会报错失效，但是签其他 app 又不报错。

日志里的对应记录（全部为 `SEAL-AUTH-107` 或 `SEAL-AUTH-102c`）：

| 时间 | 事件 |
|---|---|
| 20:47:25 / 20:46:59 | 准备签名：抖音（`mar***7***@gmail.com`） |
| 20:49:40 | `SEAL-AUTH-102c` 账号需要重新验证：Apple 返回：认证状态无效 |
| 20:52:00 | 准备签名：抖音 |
| 20:54:05 | `SEAL-AUTH-102c` |
| 20:55:51 | 准备签名：抖音 |
| 20:58:12 | `SEAL-AUTH-102c`（换账号 `zho***o***@qq.com` 后） |
| 21:02:04 | `SEAL-AUTH-107` Apple ID 会话已过期 |
| 21:13:35 / 21:16:08 | 准备签名：抖音 |
| 21:15:41 / 21:18:16 | `SEAL-AUTH-107` |
| 21:29:29 / 21:48:26 / 21:48:48 | 准备签名：抖音 |
| 21:31:46 / 21:51:26 | `SEAL-AUTH-107` |

**抖音在这份日志里没有一次成功。** 反复重试、换账号（`gmail` → `qq`）都是同一个错。

---

## 二、根因

### 2.1 决定性证据：同一账号、同一时段，别的 App 能成功

| 时间 | App | bundle ID 数 | 结果 |
|---|---|---|---|
| 20:55:42 | Sollin Player | 2（主 + NowPlayingWidget） | **续签并安装成功** |
| 21:07:38 | Kazumi | 1 | **签名并安装成功** |
| 21:13–21:51 | **抖音** | **9**（主 + 8 扩展） | 全部 `AUTH-107` |

`mar***7***@gmail.com` 在 **21:07:38 刚成功签完 Kazumi**，6 分钟后签抖音就报「登录过期」。账号不可能在 6 分钟内自然过期。

### 2.2 更硬的证据：报错前 1–3 秒，证书申请刚刚成功

```
21:15:40  签名  证书决策：Apple 证书列表暂不可用，复用本机证书 …6D3E4858；本地有效期已通过完整 7 天校验
21:15:41  错误  签名  [SEAL-AUTH-107] Apple ID 会话已过期
```

同样的组合在 21:18:14→21:18:16、21:31:43→21:31:46 各出现一次。

**证书申请（`.preparingCertificate`）能成功，说明 session 在 Apple 服务端仍然有效。** 紧接着的 App ID 阶段就报 1100「session has expired」——这不是真的登录过期。

### 2.3 机制

`ApplePortalSigningService.prepareProfile` 分两个串行阶段：

- **Phase 1**（`ApplePortalSigningService.swift:1319` 起）：对主 App + 每个扩展各做一次
  `fetchAppIDs` → 必要时 `addAppID` → `updateFeatures`
- **Phase 2**（`:1433` 起）：对每个已就绪的 App ID 各做一次 `fetchProvisioningProfile`
  （内部还含 delete + 重新 fetch）

抖音 8 个扩展 → **9 个 bundle ID** → Phase 1 至少 9 次 `addAppID` + 9 次 `updateFeatures`，
Phase 2 再 9 次（每次实际 2–3 个请求）。**短时间二十余次连发请求**，触发 Apple 对免费账号
（Personal Team）的短时频率限制，Apple 直接掐断会话并返回 `1100 Your session has expired. Please log in.`。

这解释了用户的「无论怎样都报错失效」：按提示去「我的」重新验证 Apple ID 确实能拿到新 session，
但**再签抖音又会密集请求 → 再次被掐断**，形成死循环。用户的观察「签其他 app 又不报错」也完全吻合 ——
Kazumi 只要 1 个 bundle ID、Sollin Player 只要 2 个，请求量不足以触发限流。

### 2.4 代码侧已有的痕迹

`ApplePortalSigningService.swift` 里原本就留了一条注释：

> Apple 会话过期（1100）在 App ID 创建阶段也会出现（**如抖音签名时**），必须与账户阶段一致归为 SEAL-AUTH-107

说明这个现象此前被观察到过，但只做了**错误分类**（把 1100 归到 AUTH-107），
没有处理**限流本身**。分类正确了，问题还在。

---

## 三、第二个问题：「id 有足够的名额」这个前提可能是误读

### 3.1 文案 bug（已修）

```
Seal/Features/Settings/SettingsViewModel.swift:1261
message: "Apple App ID 已同步：\(merged.usedBundleIDCount) 个可用 App ID"
```

`usedBundleIDCount` 的定义（`ApplePortalInventoryService.swift:12`）：

```swift
var usedBundleIDCount: Int {
    Set(appIDs.map { $0.bundleIdentifier.lowercased() }).count
}
```

**它是「已注册存活的 App ID 数量」，不是剩余名额。** 文案写成「N 个可用」语义正好相反：
日志里的 `Apple App ID 已同步：10 个可用 App ID` 实际含义是**已经用满 10 个**（免费账号上限）。

同一字段在 `CertificatesRootView.swift:233` 用的是 `"已签名 \(n) / 10"` —— 那个是对的。
两处口径不一致，用户读日志时被误导。

### 3.2 但名额不是本次的直接原因

本次失败全部是 `AUTH-107`，**没有一次** `SEAL-APPID-304`（「7 天内最多注册 10 个 App ID」）。
名额上限确实在 2026-09-13 撞到过（`SEAL-APPID-305`：当前 Apple ID 已有 10 个 App ID），
但 09-16 这一轮不是。

### 3.3 需要你核对的结构性约束（代码无法绕过）

免费账号的 App ID 名额是 **7 天滑动窗口内最多 10 个**（不是「当前存活 ≤ 10」，
见 `ApplePortalSigningService.swift:1307-1311` 的注释）。而：

- 抖音 = 主 App + 8 扩展 = **9 个 App ID**
- Seal 自己 = 1 个（`com.mjorb.seal.*`）
- 其他 App 各 1 个（Kazumi、Sollin Player、3105…）

**一轮抖音签名就吃掉 90% 的名额。** 7 天后 App ID 过期需重新注册，又是一轮消耗。
这是 Apple 侧的产品约束，代码层面无解。可选的应对：

1. **抖音优先用付费账号签**（付费账号上限 100+，且可删 App ID）
2. 接受**丢弃部分扩展**（`allowDroppingExtensions`，Seal 已实现降级路径）
3. 给抖音单独留一个 Apple ID，不与其他 App 混用

---

## 四、已实施的改动

### 4.1 Apple 请求节流（`ApplePortalSigningService.swift`）

新增全局 actor `AppleRequestThrottle`，并把它挂到 **`withAppleTimeout` 的开头**：

```swift
func withAppleTimeout<T: Sendable>(...) async throws -> T {
    // 先过全局节流，再发请求：这是所有 Apple 请求的必经之路。
    await AppleRequestThrottle.shared.wait()
    ...
}
```

**为什么选这个位置**：`withAppleTimeout` 是所有 Apple 请求的唯一入口，
一处覆盖全部调用点，不必逐个包装，将来新增的调用也不会漏。

**为什么不会拖慢正常签名**：节流器只在「相邻请求间隔 < 0.4 秒」时才等待。
`waitForCreatedCertificate` 的 500ms 轮询、用户手动触发的单 App 签名都不受影响。

### 4.2 1100 退避重试（`withSessionRecovery`）

对 `addAppID` 与 `fetchProvisioningProfile` 包一层：

```swift
private static let sessionRecoveryBackoffNanoseconds: [UInt64] = [
    1_500_000_000, 4_000_000_000, 8_000_000_000
]
```

命中 1100 时退避重试（累计最多等 13.5 秒），重试耗尽才向上抛。

**只对 1100 重试**：网络超时、Bundle ID 冲突（9400）、名额上限（3013）都必须立即失败，
否则会把本该快速失败的场景拖成假等待。

### 4.3 修正 App ID 阶段的 1100 文案

同一个 1100 在两个阶段含义不同，文案不能共用：

- `.account` 阶段 → 真的登录过期 → 保留「去「我的」重新验证」
- `.appID` 阶段 → 证书申请刚成功，session 还有效 → 改为
  **「Apple 暂时拒绝了请求」+「请先等几分钟再重试」**

这是打断死循环的关键：用户不会再被反复引导去做无效的重新验证。

### 4.4 消除 `contains("1100")` 子串误判

原代码用 `diagnostic.contains("1100")` 判定会话过期，会把形如
`com.example.app1100` 的 Bundle ID 报错误判成登录过期。
统一改为 `ApplePortalSigningService.isSessionExpiredError(error)`（只认错误码 1100 与官方英文文案）。

### 4.5 通道失败熔断 + 批量续签解阻塞

**背景**：`startBatchRefresh` 在进入续签循环前 `guard await refreshSigningChannel()`，
把整段隧道诊断（reset + 18s RSD 握手 + 36×500ms 轮询，硬超时 75s）压在「正在连接设备」上 ——
这是「点续签后卡很久」的**第二个入口**（第一个是单签，已在上一轮修复）。

**为什么不能直接删掉那个 guard**：`MinimuxerInstallChannel.startOnce` 失败时**不写缓存**，
去掉前置等待后，通道不可用会让 N 个 App 各自重跑一遍 75s 诊断（N×75s），比原来更糟。

**做法**：先给通道加熔断，再解阻塞。

```swift
// MinimuxerInstallChannel
private static let failureCooldownSeconds: TimeInterval = 60
if let lastFailureAt, let lastFailure,
   Date().timeIntervalSince(lastFailureAt) < Self.failureCooldownSeconds {
    throw lastFailure
}
```

配合既有的 `inFlightStart` 单飞：**整轮批量只付一次诊断代价**，
第一个 App 跑诊断（其他 App 通过单飞合并 await 同一个 task），失败后写入熔断，
后续 App 在窗口内快速失败。

**熔断不会挡住用户手动重试**：用户发起的会话（`runSigning` / `startBatchRefresh` /
`refreshSigningChannel`）都会在开始时显式调用 `clearFailureCooldown()`，
只有**同一轮批量内部**的连续调用才吃熔断。

**一个必须注意的坑**：`clearFailureCooldown()` 被声明为 **protocol requirement**
（而不是只放在 extension 里）。只在 extension 里给默认实现的话，`any InstallChannel`
会静态派发到默认空实现，`MinimuxerInstallChannel` 的覆写永远不会被调用 ——
表现是「用户手动重试也一直被拒」，而守卫全绿。同类坑在本仓 `install(onProgress:)` 上踩过一次，
已在守卫脚本里加了断言锁住。

---

## 五、待验证（需在 macOS 侧执行）

本机（Windows）无 Swift 工具链，无法编译验证。

1. `bash Scripts/verify-signing-model.sh`（xcodegen + 单测 + rork-sign + 未签名 IPA 校验）
2. 云构建三 job：`build-package` / `swift-regression` / `rork-sign-tests`
3. **真机重点**：
   - 签抖音：观察日志里是否出现「Apple 会话疑似被限流，退避 N 秒后重试…」
   - 若退避后成功 → 根因确认
   - 若退避耗尽仍失败 → 看错误标题是否为「Apple 暂时拒绝了请求」（而不是「登录过期了」）
   - 批量续签：点「全部续签」后不应长时间停在「正在连接设备」
   - VPN 未开启时批量续签：第一个 App 付诊断代价，后续应快速失败，不是整批卡死

## 六、待观察的风险

1. **节流可能不够**：0.4 秒 × 二十余次 ≈ 8 秒额外耗时。若 Apple 的限流窗口更长，
   需要把 `minimumInterval` 调大（建议先观察真机日志再调）。
2. **退避可能不够**：13.5 秒累计退避若不足以让 Apple 放行，需要加长或加次数。
3. **熔断窗口 60 秒**：若一轮批量超过 60 秒，中途过期会导致又一个 App 重跑诊断。
   真机观察批量耗时后再定。
