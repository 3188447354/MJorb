# 只有抖音签不上：App ID 创建顺序 + 缺一条能把两种成因分开的诊断

- 日期：2026-09-17
- 触发：用户反馈「id 失效就是签抖音会这样，其他的不会，并且重新添加 id 签抖音不行，签其他 app 就行」
- 相关日志码：`SEAL-AUTH-107`（App ID 阶段会话失效）、`SEAL-APPID-304`（7 天 10 个上限）

## 现象

- 同一个 Apple ID：**签抖音失败**（提示 Apple ID 失效），**签其它 App 正常**。
- 把 Apple ID 删掉重新添加，再签抖音**仍然失败**。
- 三个账号里只有 `3188447354@qq.com`（1/10）的 App ID 名额够签抖音。

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

**判读**：`需新注册 K` 大于账号剩余名额 ⇒ 名额问题；`K` 很小却仍报 1100 ⇒ 限流。

## 为什么没有同时加长退避

`withSessionRecovery`（遇 1100 退避 1.5/4/8 秒）在**三个** portal 变更上早就有
（创建 App ID / 申请描述文件 / 创建证书）。在没有日志证据前加长退避属于「先调参后取证」。
本轮只做两件事：一条确定性的逻辑缺陷 + 一条取证手段。

## 守卫与测试

- `Scripts/verify-release-safety.py` R26：5 条源码断言 + 5 个变异锚点
  - 顺序函数必须存在**且真的被调用**；
  - 不得退回 `mappings.sorted(by: { $0.key < $1.key })`；
  - `preparationOrder` 体内必须真的判 `lhsIsMain != rhsIsMain`（不是只留个名字）；
  - 主 App 之外必须按原序稳定排序；
  - 名额诊断文案必须存在（无条件写）；
  - 单测里必须有 `ordersAppIDCreationWithTheMainAppFirst` 与 `order.first?.mapped == main`。
  - 变异：让主 App 优先失效 / 把稳定排序反过来 / 退回字母序调用 / 删掉名额诊断 / 把单测改宽。
- `SealTests/Signing/ApplePortalSigningFailureTests.swift`：+2 单测
  - `ordersAppIDCreationWithTheMainAppFirst`（刻意构造 `com.example.demo-ext` 排在
    `com.example.demo` 之前的形态）；
  - `keepsAlphabeticalOrderWhenMainBundleIDIsNotInMappings`（退化路径不崩、不漏项）。

## 验证状态

- 静态守卫：**PASS（349 源码断言 + 187 变异）**
- 云构建 + 真机：待验

## 待真机确认的判据

用户下次签抖音时，日志里应能看到：

1. `App ID 名额：… 需新注册 K 个`；
2. `K` 与账号剩余名额的关系（决定是名额问题还是限流）；
3. 若仍失败，是否有 `SEAL-AUTH-107`，以及它之前有没有「退避 N 秒后重试 创建 App ID …」。

- 若 `K` 很小却仍报 1100 ⇒ 是**限流**，下一轮再加长退避 / 加大请求间隔；
- 若 `K` 大于剩余名额 ⇒ 是**名额**，引导用户换账号或等 7 天窗口滚动；
- 若主 App 成功、扩展被部分丢弃 ⇒ 顺序修复生效，属**预期内的降级**。
