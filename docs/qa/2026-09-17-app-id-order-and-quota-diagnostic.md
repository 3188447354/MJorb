# 只有抖音签不上：App ID 创建顺序 + 缺一条能把两种成因分开的诊断

- 日期：2026-09-17
- 触发：用户反馈「id 失效就是签抖音会这样，其他的不会，并且重新添加 id 签抖音不行，签其他 app 就行」
- 相关日志码：`SEAL-AUTH-107`（App ID 阶段会话失效）、`SEAL-APPID-304`（7 天 10 个上限）

## 现象

- 同一个 Apple ID：**签抖音失败**（提示 Apple ID 失效），**签其它 App 正常**。
- 把 Apple ID 删掉重新添加，再签抖音**仍然失败**。
- 三个账号里只有 `318***5***@qq.com`（1/10）的 App ID 名额够签抖音。

## 关键事实

| 事实 | 数值/出处 |
|---|---|
| 抖音的结构 | 主 App + **8 个扩展** |
| 一次签名要注册的 App ID | **9 个**（主 App 1 + 扩展 8） |
| 免费账号 App ID 上限 | **7 天内最多 10 个**（滑动窗口，不是存活数） |
| 名额归属 | 主 App 与扩展**共享**同一个 10 个名额 |
| 降级规则（不对称） | 扩展创建失败 ⇒ **丢弃扩展继续签名**；主 App 创建失败 ⇒ **整个签名抛错** |

## 根因（两条，互相独立）

### 1. 创建顺序：扩展会先把共享名额吃掉

`provisioningProfiles` 的 Phase 1 原实现：

```swift
for (originalBundleID, mappedBundleID) in mappings.sorted(by: { $0.key < $1.key }) {
```

即按 Bundle ID **字母序**创建。而 `-` 的码位（0x2D）小于 `.`（0x2E），所以形如
`com.x.app-ext` 的扩展会排在 `com.x.app` **前面**。

后果：扩展先消耗掉有限名额；轮到主 App 时名额已空 ⇒ 主 App 的 `addAppID` 失败
⇒ 触发 `guard mappedBundleID != mappedMainBundleID else { throw error }`
⇒ **整个签名失败，而名额已经白花**。

**隐蔽性**：名额充足时两种顺序结果完全一样，所以这个缺陷只在真机上、且只在
「名额不够 + 扩展字母序靠前」时暴露。

### 2. 诊断缺失：两种成因在日志里同形

「App ID 名额不够」与「请求过密被限流」**都**表现为 App ID 阶段报 1100（会话失效），
但处置完全相反：

- 名额不够 ⇒ 换账号 / 等 7 天；
- 限流 ⇒ 等几分钟重试。

缺一条无条件诊断时，用户发来的日志**分不出是哪一种**。

### 3. 退避重试漏在第 4 类 portal 写入上：`updateFeatures` 没有 1100 重试

顺着「抖音为什么特别容易撞限流」去**枚举门户写入**（`grep ALTAppleAPI.shared.`），
14 个调用点里有 9 个是写入：

| 原语 | 在哪 | 在 per-bundle-ID 循环里？ | 有 1100 退避重试？ |
|---|---|---|---|
| `addAppID` | Phase 1 | 是（抖音 **9 次**） | ✅ |
| `update`（`updateFeatures` → `submitUpdatedAppID`） | Phase 1 | **是（抖音 9 次）** | ❌ **漏了** |
| `fetchProvisioningProfile`（内部还会 delete） | Phase 2 | 是（9 次） | ✅ |
| `addCertificate` | 证书阶段 | 否（1 次） | ✅ |
| `addAppGroup` / `assign` / `fetchAppGroups` | `assignAppGroups` | 是（付费账号，每 ID 最多 3 次） | ❌ 漏了 |
| `registerDevice` / `revoke` | 一次性 | 否 | 刻意不覆盖（不在循环里、不构成突发） |

⇒ Phase 1 每个 bundle ID 实际要发 **2 次**写请求，抖音一次签名是 **18 次**突发，
而其中一半（9 次 `updateFeatures`）完全没有保护。

**漏掉它的两种后果都不报错**（这才是它值钱的地方）：

1. **主 App** 撞 1100 ⇒ 落到 `guard mappedBundleID != mappedMainBundleID else { throw error }`
   ⇒ **整个签名失败**，用户看到的只是「Apple ID 失效」；
2. **扩展** 撞 1100 ⇒ 走降级分支把 `requestedEntitlements[mappedBundleID] = [:]` **清空**后继续签
   ⇒ 签名「成功」，但扩展在真机上缺权限（静默降级比失败更难查）。

**为什么漏了却一直没被发现**：守卫 R24 的断言是
`portal_source.count("withSessionRecovery(") == 3` —— 那个 **3 是从当时的代码数出来的**，
于是它把「覆盖不全」固化成了期望值。

## 修复

### 顺序抽成纯函数，主 App 优先

`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`

```swift
enum ApplePortalAppIDResolver {
    static func preparationOrder(
        mappings: [String: String],
        mappedMainBundleID: String
    ) -> [(original: String, mapped: String)] {
        mappings
            .map { (original: $0.key, mapped: $0.value) }
            .sorted { lhs, rhs in
                let lhsIsMain = lhs.mapped == mappedMainBundleID
                let rhsIsMain = rhs.mapped == mappedMainBundleID
                if lhsIsMain != rhsIsMain { return lhsIsMain }
                return lhs.original < rhs.original
            }
    }
}
```

Phase 1 改用它。主 App 优先之后，最坏是「部分扩展被丢弃」（界面本来就会列出被丢弃的扩展），
而不是「这个 App 签不上」。主 App 之外仍按字母序 —— **顺序必须稳定**，否则重试时的日志对不上。

抽成纯函数是为了能写单测：**源码断言只能证明函数存在，证明不了它真的把主 App 排在前面**。

### 无条件写一条名额诊断

```swift
await diagnostic(
    "App ID 名额：本次需 \(mappings.count) 个（主 App 1 + 扩展 \(extensionAppIDCount)），"
        + "账号上已有 \(existing.count) 个、其中可复用 \(reusableAppIDCount) 个，"
        + "需新注册 \(mappings.count - reusableAppIDCount) 个"
)
```

**判读**：⚠️ **不能用 `N`（账号存活 App ID 数）去算「剩余名额」** —— 上限是
「**7 天内注册数的滑动窗口**」，不是「存活数 ≤ 10」（源码注释 1477–1482 行写得很清楚：
窗口滚动后老 App ID 仍在存活列表里、却已不算进当周窗口，账号可以合法攒到 >10 个）。

这条诊断真正的用处是**排除假设**：

- **`K` = 0** ⇒ 本次一个 App ID 都不用新建 ⇒ **不可能**是「建号突发被限流」，去别处找原因；
- **`K` 很大**（抖音通常是 9）⇒ 本次确实是一轮突发，限流假设成立。

**「名额满」与「限流」的真正判据是失败时的日志码**（Apple 的措辞会变，错误码不会）：

| 日志码 | 含义 | 依据 |
|---|---|---|
| `SEAL-APPID-304` | **App ID 名额满** | Apple 返回 1009 / 3013 |
| `SEAL-AUTH-107` | **限流**（App ID 阶段返回 1100） | 会话在服务端仍有效（证书申请刚成功过） |

### 把退避重试补到所有 per-bundle-ID 的 portal 写入上

```swift
let updatedAppID: ALTAppID =
    try await withSessionRecovery("更新应用能力 \(mappedBundleID)") {
        try await updateFeatures(
            appID: appID,
            application: application,
            team: team,
            session: session
        )
    }
appID = updatedAppID
if team.type != .free {
    try await withSessionRecovery("分配 App Group \(mappedBundleID)") {
        try await assignAppGroups(...)
    }
}
```

副作用是一条额外的诊断：每次重试都会写
`Apple 会话疑似被限流，退避 N 秒后重试 更新应用能力 <bundleID>（第 N 次重试）`
—— 用户下次的日志能直接看出限流打在**哪个阶段**，而不只是「App ID 阶段」。

⚠️ **代价**：最坏情况下 18 次写请求各退避 3 次（累计 13.5 秒）⇒ 单次签名可能多等几分钟
（阶段一直停在「正在准备 App ID」）。这是**有界**的，而且换来的是「不必让用户白跑一趟
重新验证 Apple ID」；但看到用户反馈「卡很久」时，先查日志里有没有那些退避行。

## 为什么没有同时加长退避

`withSessionRecovery` 的重试间隔是 1.5 / 4 / 8 秒（累计 13.5 秒）。在没有日志证据前加长它
属于「先调参后取证」。本轮做的是三件**不需要新证据**的事：一条确定性的逻辑缺陷（顺序）、
一条取证手段（名额诊断）、一处确定的覆盖缺口（`updateFeatures` 漏了重试）。
**要不要动退避时长，等拿到那条日志再说。**

## 守卫与测试

- `Scripts/verify-release-safety.py` R26：5 条源码断言 + 5 个变异锚点
  - 顺序函数必须存在**且真的被调用**；
  - 不得退回 `mappings.sorted(by: { $0.key < $1.key })`；
  - `preparationOrder` 体内必须真的判 `lhsIsMain != rhsIsMain`（不是只留个名字）；
  - 主 App 之外必须按原序稳定排序；
  - 名额诊断文案必须存在（无条件写）；
  - 单测里必须有 `ordersAppIDCreationWithTheMainAppFirst` 与 `order.first?.mapped == main`。
  - 变异：让主 App 优先失效 / 把稳定排序反过来 / 退回字母序调用 / 删掉名额诊断 / 把单测改宽。
- `Scripts/verify-release-safety.py` R24（**重写**）：从「数个数」改成「按操作逐个点名」——
  5 个 label 各一条断言 + 1 条计数兜底（`== 5`），并把「刻意不覆盖 `revoke` /
  `registerDevice` / `fetch*`」的理由写进守卫。新增 2 个变异锚点
  （把 `updateFeatures` / `assignAppGroups` 退回直接请求）。
  > 原来那句 `count("withSessionRecovery(") == 3` 里的 3 是**从当时的代码数出来的**，
  > 于是它把「覆盖不全」固化成了期望值。改成逐个点名后，失败信息能直接说出**少的是哪一个**。
- `SealTests/Signing/ApplePortalSigningFailureTests.swift`：+2 单测
  - `ordersAppIDCreationWithTheMainAppFirst`（刻意构造 `com.example.demo-ext` 排在
    `com.example.demo` 之前的形态）；
  - `keepsAlphabeticalOrderWhenMainBundleIDIsNotInMappings`（退化路径不崩、不漏项）。

## 验证状态

- 静态守卫：**PASS（351 源码断言 + 189 变异）**
- 云构建 + 真机：待验

### 顺带踩到的坑（值得单独记）

改断言文案后**忘了同步变异锚点的「期望文案」** ⇒ 守卫报
`FAIL: Guard failed mutation check: R24: 创建证书也必须过退避重试`。
**这个报错看着像「变异没被抓到」，其实是断言已经触发、只是消息前缀对不上** ——
不要因此去改实现或删锚点，先把期望文案对齐。

## 待真机确认的判据

用户下次签抖音时，日志里应能看到：

1. `App ID 名额：… 需新注册 K 个`（用来**排除**限流假设：`K` = 0 就不可能是建号突发）；
2. **失败时的日志码** —— 这是唯一的硬判据：
   `SEAL-APPID-304` = 名额满（Apple 返回 1009/3013）；`SEAL-AUTH-107` = 限流（1100）；
3. 若仍失败，它之前有没有「退避 N 秒后重试 创建 App ID / 更新应用能力 …」——
   有就说明限流确实发生且退避正在工作。

- 若日志码是 `SEAL-AUTH-107` ⇒ 是**限流**，下一轮再加长退避 / 加大请求间隔；
- 若日志码是 `SEAL-APPID-304` ⇒ 是**名额**，引导用户换账号或等 7 天窗口滚动；
- 若主 App 成功、扩展被部分丢弃 ⇒ 顺序修复生效，属**预期内的降级**。
