# 「签不了」的根因：anisette 是一次性快照（构建 141 / 147 真机日志）

- 日期：2026-09-19
- 日志：`Seal-log(20).txt`（构建 **1.1.16 (141)**）、`Seal-log(21).txt`（构建 **1.1.16 (147)**）
- 用户原话：**「我换了一个抖音IPa签 还是8个扩展，这次扩展签上了，但是后面seal闪退 并没有到传输安装」**
- 相关文档：[`2026-09-18-only-douyin-fails-real-chain.md`](./2026-09-18-only-douyin-fails-real-chain.md)、
  [`2026-09-18-signing-latency-attribution.md`](./2026-09-18-signing-latency-attribution.md)

## 零、摘要

| # | 结论 | 状态 |
|---|---|---|
| 1 | **「签不了」的根因是 anisette 的一次性验证码被复用到 120 秒之后** ⇒ Apple 返回 1100 | **已修 + 真机确认** ✓ |
| 2 | 本地耗时的大头是**归一化（30–35 秒）**，不是解压（7–11 秒）、更不是打包（1 秒） | 已定位 ✓ |
| 3 | 描述文件回收被**永久阻断**，原因是**整条设备查询通道不可信**（系统 App 也查不到） | 已确认，修复待做 |
| 4 | 构建 147 上 Seal 在 **`signing` 阶段直接闪退** | **未定位** ✗ |

## 一、根因：anisette 被复用到 120 秒之后

### 1.1 关键证据：**gap 之前的请求全部成功，gap 之后的第一个请求立刻失败**

`Seal-log(20).txt` 里两次尝试（**两个不同的 Apple ID**）失败形态**完全相同**：

```
23:55:31  Apple ID 已添加                        ← 登录成功 ✓
23:56:02  证书检查：远端 1 张                     ← 读证书列表**成功** ✓
23:56:05  证书自动清理完成：撤销 1/1 张非本机证书    ← 写操作**也成功** ✓
23:56:05  「签名：设备环境已就绪」                 ← anisette 在这里取
23:56:06 → 23:58:09  本地准备 **120 秒**
23:58:10  「Apple 会话疑似被限流」第 1 次          ← **失败从这里才开始** ✗
23:58:12 / 17 / 26 / 48   第 2/3/4/5 次退避（4/8/20/40 秒）
23:59:31  [SEAL-AUTH-102c] Apple 拒绝了证书请求：认证状态无效 ✗
```

⇒ **失败点与「会话」无关，与「时间」有关** ✓

### 1.2 机制

anisette 里的 `X-Apple-I-MD` 是**一次性验证码**，有效期只有几十秒；
而 `signOnce` 在**开头**取一次 anisette、建好 `session` 之后**一直用到最后**。
`prepare`（解压 + 三趟全树遍历）要 105–120 秒 ⇒ 之后所有 Apple 请求用的都是
**两分钟前**那份 anisette ⇒ Apple 判会话异常返回 **1100**。

**⇒ 这解释了为什么「换账号也一样失败」**：它是**设备身份级**的，与账号无关。

### 1.3 曾经走错的方向（记录下来避免重犯）

当晚一度把 1100 判成「限流」，理由是「紧接 3–5 次退避之后报 102c」。
**错在把「退避重试」当成了独立证据** —— 退避是 Seal 自己发的，
它恰好证明的是「1100 连续出现了 5 次」，而不是「Apple 在限流」。
真正的判据是**时间线**：gap 之前的请求全部成功。

### 1.4 修复

`prepare` 之后**重新取 anisette 并重建 `session`**（`let session` → `var session`）。
守卫 **R43**。提交 `921fa4e`。

**真机验证（构建 147）**：

```
08:09:50  签名：本地准备耗时较长（40 秒），已重建 Apple 会话（换新的 anisette 一次性码）
08:09:51  阶段进入：preparingCertificate
08:09:51  阶段进入：preparingAppID
08:09:53  阶段进入：preparingProfiles
08:10:13  阶段进入：signing          ← 一路走到重签，**比之前远得多** ✓
```

⇒ `SEAL-AUTH-102c` 在构建 147 里**没有再出现** ✓

### 1.5 顺带修掉的两条误导文案

| 问题 | 修法 | 守卫 |
|---|---|---|
| `withSessionRecovery` 把 1100 渲染成「Apple 会话疑似被限流」⇒ 把用户引向「等一会儿再试」（**退避治不好会话过期** ✗），且日志里看不到 1100 这个真正的码 | 改为「Apple 会话已过期（1100）」，并在退避全部失败时给出**可执行出路**（重新验证 / **换网络节点**） | **R42** |
| **阶段日志的闸门用错了 API**：`InstallStageTimeline.tick` 只对 `.installing` 返回 `.restart`（它是「安装计时起点」的簿记），拿它当闸门 ⇒ **只有 `installing` 会落日志** | 改为 `stage != currentStage` | **R39** |

⚠️ 第二条的教训值得单列：**用别人的函数当判据之前，先读它的实现** ——
真机实测整份日志只有 1 条 `SEAL-STAGE-001`，正是 `installing`，与「只有它放行」完全印证。

## 二、本地耗时归因：大头是**归一化**

三次拆分，前两个猜测都被实测推翻：

| 猜测 | 实测 | 结论 |
|---|---|---|
| 「打包是最大头」 | 打包 **1 秒** | ✗ |
| 「解压是最大头」 | 解压 **8–15 秒** | ✗ |
| （拆成四段后） | 见下表 | ✓ |

构建 147 真机（两次）：

| 段 | 实测 |
|---|---|
| 解压 | 7 / 11 秒 |
| 改写 | **0 / 0 秒** |
| 瘦身 | 2 / 5 秒 |
| **归一化** | **30 / 35 秒** ← 大头 |

⇒ **优化方向是减少 `normalizeRootFrameworksIntoFrameworksDirectory` 的全树遍历次数**，
不是动解压或打包。守卫 **R41**。

（总耗时也从 120 秒降到 40–52 秒 —— 新 IPA 的目录布局不同。）

## 三、描述文件回收被永久阻断：**整条查询通道不可信**

```
回收中止：阳性对照未通过（com.mjorb.seal.CT8QZ7352B 被答成未安装）；
通道判别（系统 App）：com.apple.Preferences=unavailable、com.apple.mobilesafari=unavailable
```

- 阳性对照用的是 `Bundle.main.bundleIdentifier`（**正在运行的自己**）⇒ 它**一定**装着；
- `probeInstalled` 走的是**会抛错**的 `Minimuxer.isAppInstalled(bundleId:)` 且**有界**
  ⇒ 它返回的是明确的 `false`，**不是**超时、**不是**抛错；
- **系统 App 也 `unavailable`** ⇒ **整条查询通道不可信**（不是 Seal 的 ID 问题）。

⇒ 下一步：在「探测到死」时**重建 RSD 连接**（此前一直缺的正是这条直接证据）。
守卫 **R44**。

## 四、未解决：构建 147 在 `signing` 阶段**直接闪退**

```
08:09:53  [SEAL-STAGE-001] 阶段进入：preparingProfiles
08:10:13  [SEAL-STAGE-001] 阶段进入：signing      ← 重签开始
（日志到此为止：没有打包、没有 installing、没有 error）
```

**两次运行断在同一位置** ⇒ **硬崩溃**（日志来不及 flush）。

### 已排除

- 签名器里**没有** `Data(contentsOf:)` 之类的整块载入 ✗（内存风险低）。

### 候选（**未确认，不许猜**）

`Vendor/rork-sign` 里有若干 **`precondition`**（**Release 下也会崩**，不像 `assert`），
集中在 CMS / DER / 证书链：

```
CMSGenerator.swift:279        precondition(components.count >= 2)
DEREncoding.swift:32/55/103   precondition(value >= 0) / preconditionFailure("Invalid OID arc")
AppleCertificateChain.swift:59 preconditionFailure("Embedded Apple certificate ... is invalid")
```

### 已做

重签前加**分界日志**（提交 `6569269`，守卫 **R45**）：

```
签名：开始重签（逐 Mach-O 串行）—— 待签描述文件 N 份、appGroups N 个、主 Bundle …
```

- 下次崩溃**没有**这一行 ⇒ 死在 Swift 侧准备；
- **有**这一行 ⇒ 死在 `RorkSigner` 内部。

### 顺带查清：签名器内部**为什么一行日志都没有**

`RorkSigner` **自带**一套 `SigningDiagnostics`（`context.diagnostics.info(...)` 逐 bundle 打），
但 `BundleSigningOptions.diagnostics` **默认 `.disabled`**，而 Seal **从来没设置过它**。

要接上有一个矛盾：它是**同步回调**，而 `SealLogStore` 是 **actor**（写入异步 ⇒
崩溃时挂起的日志会丢 ✗）。⇒ 等确认死在签名器内部之后再动。

### 需要的输入

**iOS 崩溃日志**：设置 → 隐私与安全性 → 分析与改进 → 分析数据 → `Seal-2026-09-19-…`。
它直接指出崩溃在哪一帧，比任何埋点都快。

## 五、本轮推送的提交（分支 `fix/signing-attribution-batch0`）

| 提交 | 内容 | 守卫 |
|---|---|---|
| `a2497f7` | 进度环去掉「假预估」——只画已确认进度 | R36 同步 |
| `7580249` | 1100 不再被说成「限流」+ 可执行出路；阶段日志闸门修正 | R42 / R39 |
| `921fa4e` | **本地准备之后重建会话（根因修复）** | R43 |
| `a41d178` | `prepare` 耗时拆四段 | R41 |
| `3da916f` | 阳性对照的判别性诊断 | R44 |
| `9ae9113` | 清理扫光移除后留下的死参数 | — |
| `6569269` | 重签前的分界日志 | R45 |

**守卫：440 源码断言 + 224 变异 PASS。**

⚠️ `6569269` 首次推送时红了一轮 CI：新增的 `diagnostic(...)` 写在
`Task.detached { ... }.value` 闭包里，**缺 `self.`**
（`call to method 'diagnostic' in closure requires explicit use of 'self'`）。
已在下一提交修正。

## 六、下一步（按信息效率排序）

1. **拿 iOS 崩溃日志** ⇒ 直接定位第四节；
2. 装含分界日志的构建重试 ⇒ 分出「Swift 侧准备」与「签名器内部」；
3. 按第二节的结论**减少归一化的全树遍历**（`strip` 与 `normalize` 两次逐文件 open 是主要成本）；
4. 按第三节的结论在**探测到死时重建 RSD 连接**。
