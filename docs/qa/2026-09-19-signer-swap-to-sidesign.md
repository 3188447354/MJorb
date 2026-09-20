# 2026-09-19 · 签名器整个换成上游 `SideSign` + `CodeSignKit`（删掉 `rork-sign`）

- 构建基线：`0d34c95`（CI 全绿，产物 `Seal-173`）
- 本轮改动：删 `Vendor/rork-sign` ＋ 把签名器换成上游 → 收尾清理
- 用户指令原话：「**一个代码不漏地给我抄 不要打补丁 签名器不一样你就换啊 这个签名不是签不了大包吗**」
  ＋「**禁止乱发明**」＋「**照抄吧**」；方案 **B**（只抄签名能力，不带 anisette / 门户）

---

## 一、现象（为什么必须换）

| 现象 | 证据 |
|---|---|
| 签**大包**时 Seal 被 iOS 杀掉，**并且连累后台** | 真机 `JetsamEvent`：`largestProcess = "Seal"`，`rpages 129697 × 16KB = **2.11 GB**`；用户原话「网易云播放的音乐被杀掉了，LOCALDEVvpn 也被杀掉了」✓ |
| 签名阶段**日志一片空白**，死在哪个 bundle 都不知道 | 构建 147：`signing` 阶段直接闪退，导出日志到此为止 ✗ |
| 而 **SideStore 同样在手机上签大包，没有这个问题** | SideStore 用的是 `SideSign` → `CodeSignKit` ✓ |

⇒ **判据**：既然上游已经解决，就**照抄上游**，而不是继续在 `rork-sign` 上打补丁 ✓。

---

## 二、根因

**内存峰值来自「整块读 ＋ 原地改」**（Swift COW 在「唯一引用」时**不复制**，
于是「读一份 ＋ 改一份」＝ **2 份**）：

```
rork-sign：Data(contentsOf:) 整块读  →  原地 replaceSubrange  ⇒ 峰值 2×  ✗
```

**上游的做法是「mmap 读 ＋ 复制后改」⇒ 全程 1 份** ✓（逐行核实）：

```swift
// CodeSignKit/Sources/MachOParser.swift:154,157
self.data = try Data(contentsOf: execURL, options: .mappedIfSafe)   // mmap：0 常驻内存
// CodeSignKit/Sources/MachOSigner.swift:301
var finalBinary = workingData.subdata(in: 0..<min(codeLimit, workingData.count))  // 复制后改
```

---

## 三、修复（做了什么）

### 3.1 换成上游的两个包（原样 vendor）

| | 换之前 | 换之后 |
|---|---|---|
| 签名内核 | `Vendor/rork-sign`（`rorkai/rork-sign` 0.6.5 ＋ **4 个文件**的 Seal 补丁 ✗） | `Vendor/CodeSignKit`（**只改 `Package.swift` 一行** ✓） |
| 重签层 | `Seal/Infrastructure/Signing/RorkAppSigner.swift`（Seal 自写 ✗） | `Vendor/SideSign` ＋ 薄适配 `Seal/Infrastructure/Signing/SideSignAppSigner.swift` ✓ |
| 签名身份读取 | `RorkSigner.checkMachOCodeSignatures`（整块读 ✗） | `CodeSignKit.MachOParser`（mmap ✓）—— `AppBundleSigningIdentityReader` ✓ |

`Vendor/CodeSignKit` 与上游 `diff -r -w` **只差 `Package.swift`** ✓（`swift-crypto` 4.3.1 → 4.5.2，
不改会与根包冲突 ✗）。

### 3.2 `Vendor/SideSign` 的删减（方案 B：只抄签名能力）

删掉 `Sources/Anisette/`、`Sources/DeveloperPortal/`、10 个属于这两层的 `Models/*.swift`、
`Compatibility.swift`、`Constants.swift` 的 `Anisette` 段、
`Logging.swift` 的 `import AnisetteKit` ＋ `AnisetteKitLogging.setLogging` ✓。

**本轮收尾又补删了两处**（都是「上一层的必然残留」，不删就编译不过 ✗）：

| 删掉 | 原因 |
|---|---|
| `Vendor/SideSign/CLI/` ＋ `Package.swift` 的 `sidesign` 产品与 `executableTarget` | `CLI/CommandHandler.swift:13` 仍 `import AnisetteKit`，并引用 `DeveloperPortal` / `CertificateRequest` / `CertificateType` / `ProfileType` ✗ ⇒ **根本编译不过** |
| `Tests/SideSignTests` 里 2 个用例（`certificateRequestCSRGeneration` / `developerPortalSingleton`） | 同上（其余 3 个：`Device` 模型 ＋ 两个 `Archive` 往返 ⇒ **保留** ✓） |

### 3.3 `ios.yml`：`rork-sign-tests` → `signer-tests`

`Vendor/rork-sign` 删了之后，原来那个 job 会**直接失败** ✗。**不是简单删掉**，
而是改成测**现在真正在跑的那两个包** ✓（保住「签名核心独立回归门」这个作用 ✓）：

```yaml
signer-tests:
  - Run CodeSignKit unit tests   # working-directory: Vendor/CodeSignKit
  - Run SideSign unit tests      # working-directory: Vendor/SideSign
```

`publish-release.needs` 同步改成 `[build-package, signer-tests, swift-regression]` ✓。

### 3.4 顺手修掉一个真缺陷（注释被反引号掏空）

`Vendor/SideSign/Sources/Logging.swift:10-12` 的注释里，两个标识符
（`AnisetteKit` / `AnisetteKitLogging.setLogging`）**消失了** ✗ ——
正是本仓记过的「`python -c` 里的反引号被 bash 先当命令执行」事故 ✓。已按上游原文补回 ✓。

### 3.5 把 6 处「排障判据」注释从 `RorkSigner` 改成新签名器

换签名器后，下面这些**注释还在教人去找 `RorkSigner`** ✗ —— 它们不是废话，
而是**真机上用来定位崩溃点**的判据（例如「有这一行 ⇒ 死在签名器内部」）✓
⇒ 留着会把下一次排查带偏 ✗：

| 文件 | 处数 | 原文 → 改后 |
|---|---|---|
| `Seal/Infrastructure/Signing/ApplePortalSigningService.swift` | 3 | 「传给 `RorkSigner` 确保 appGroups 正确」/「死在 `RorkSigner` 内部」/「等 `RorkSigner.checkMachOCodeSignatures` 也换掉后再清理」 |
| `Seal/Infrastructure/Signing/SigningWorkspace.swift` | 3 | 「后续统一由 `RorkSigner` 重签」/「统一交给 `RorkSigner` 处理」/「原样保留交由 `RorkSigner` 重签」 |

改后一并写明**上游的能力缺口** ✓（`verboseLog` 走 `print` ⇒ 进不了导出日志 ✗）。
`SideSignAppSigner.swift` 里保留的 `RorkAppSigner` 字样是**刻意的历史出处标注** ✓，不动 ✓。

---

## 四、守卫与测试

| 守卫 | 处置 |
|---|---|
| **R38**（签名缓存必须传进 `AppSigningOptions`） | **移除** ✗ —— 上游 `SideSign` / `CodeSignKit` **没有签名缓存** ⇒ 断言与变异锚点都失去对象；**知识已留档**（每次全量重签 ⇒ 大包 CPU 预算压力更大 ✓） |
| **R46**（签名器逐 bundle 诊断必须打开） | **移除** ✗ —— 上游只有 `verboseLog`（走 `print` ⇒ 进不了导出日志 ✗）与 `signApp(progress:)`（只有计数、没有回调 ✗）；**知识已留档**（真机靠「日志戛然而止」推断 ✓） |
| **R50**（签名器 input / executable 必须 mmap） | **判据重定向为 R57** ✓ —— 同一条「mmap 读 ＋ 复制后改」现在钉在上游 `CodeSignKit` 上 ✓ |
| **R52**（签名器 FairPlay 补丁必须保留） | **移除** ✗ —— 但**已留档为最高严重级风险** ✓（见第五节） |
| **R56**（新增） | `ios.yml` 必须保留 `signer-tests`，且 `working-directory` 指向 `CodeSignKit` ＋ `SideSign` ✓（防「job 名还在、其实什么都没测」✗） |
| **R57**（新增） | 上游 `CodeSignKit/MachOParser` 必须 **mmap 读** ＋ `MachOSigner` 必须 **`subdata` 复制后改** ✓；配一个「改回整块读」的变异锚点 ✓ |

**本机跑完整守卫**：`Source regression checks: 447` / `Guard mutation checks: 230` / **PASS** ✓
（耗时 3 分 03 秒 ✓）。

---

## 五、🔴 待真机验证 → ✅ **已全部验证通过**（2026-09-20，构建 175）

> 真机日志：`Seal-log(28).txt`（**定版 `构建 1.1.16 (175)`** ✓）

| # | 风险 | 结果 |
|---|---|---|
| 1 | 🔴 **装完能不能启动** —— 上游**不处理 FairPlay `cryptid` 清零** ✗ | ✅ **两个 App 都能打开**（LiveContainer 4.8 MB ＋ 抖音 657.6 MB）⇒ **这条风险排除** ✓ |
| 2 | 🔴 **大包会不会被 CPU 预算杀掉** —— 没有签名缓存 ⇒ 全量重签 ✗ | ✅ **没被杀** —— 抖音全程走完：本地准备 44 秒（解压 7 ＋ 归一化 37）＋ **重签 78 秒** ＋ 打包 43 秒 ＋ 安装 121.6 秒 ✓ |
| 3 | 🟡 **日志里还能不能看出「死在哪个 bundle」** —— 逐 bundle 诊断没了 ✗ | ⚠️ **仍是已知的能力退化** ✓（本次没崩所以没暴露；不阻塞 ✓） |

### 5.1 真机时间线（`Seal-log(28).txt`）

1. `09:16:52–09:17:11` **Seal 自替换** —— 旧证书无本机私钥 ⇒ 轮换（撤销 …24C2B3F1 → 新建 …084ACB48 ✓）
2. `09:21:35–09:22:14` **LiveContainer 签名 ＋ 安装成功** ✓（4.8 MB，安装 4.1 秒）
3. `09:23:49–09:24:54` 抖音**第一次失败** ⇒ `SEAL-APPID-304`（免费账号 10 个 App ID 名额满 ✗）
4. `09:26:21–09:31:39` 抖音**第二次成功** ⇒「签名并安装成功」✓

⚠️ 第 3 步**不是缺陷** ✓：第一次「已有 9 个、可复用 0 个 ⇒ 需新注册 9 个」撞上限，
而**第一次其实已经把前几个 App ID 建好了** ⇒ 第二次「已有 10 个、可复用 9 个 ⇒ 需新注册 0 个」⇒ 成功 ✓。
这是免费账号的**硬限制**，重试即可 ✓。

### 5.2 真机暴露的两处「日志不可信」

| 现象 | 处置 |
|---|---|
| `新算 0 个 / 缓存命中 0 个（续签同一个 App 时命中数应当接近总数）` ✗ —— 上游**没有缓存** ⇒ 恒为 0，那句括号**永远不可能成立**，而日志是唯一排障通道 ⇒ 会让人以为「缓存没生效」 | ✅ **已修**（2026-09-20）：改成「（上游签名器无缓存 ⇒ 每次全量重签）」✓ |
| `回收中止：阳性对照未通过（com.mjorb.seal.CT8QZ7352B 被答成未安装）` ✗ | ⏸️ **已查一轮**（与换签名器无关 ✓）—— 见下面 5.2.1 |

#### 5.2.1 🔴 **更正：阳性对照的 ID 选得是对的**（2026-09-20 09:45）

我先前写的「阳性对照挑的是**旧 Team 后缀的 Seal 自己**，而那个 ID 已被自替换覆盖 ⇒ 必然答未安装」
**是错的** ✗ —— 核对代码：用的是 `Bundle.main.bundleIdentifier`（**当前正在运行的 Seal 自己** ✓），
而 `com.mjorb.seal.CT8QZ7352B` **就是**当前 Seal 的 ID（自替换的目标 ✓）⇒ **对照 ID 选得对** ✓。

**教训：结论要落在代码上，别靠日志里那个字符串猜** ✗。

**真实规律**（`Seal-log(28).txt` 逐行核对）：

| 时间 | 距启动 | 结果 |
|---|---|---|
| `09:14:44` | 冷启动后 **22 秒** | ❌ 中止（同行带 `dump 尝试 3 次`） |
| `09:15:00` / `09:16:48` | 38 秒 / 2 分 | ✅ 正常 |
| `09:18:11` | 自替换重启后 **60 秒** | ❌ 中止 ×2（同行带 `dump 尝试 2 次`） |
| `09:21:19` 起 | — | ✅ 正常 |

⇒ **两次中止都在「刚启动」，且都伴随 `dump 尝试 N 次`；16 秒后再跑就正常** ✓
⇒ **强烈指向「启动早期安装通道还没就绪」** ✓ —— fail closed **正确** ✓（**不是数据安全问题** ✓）。

⚠️ 根因**尚未最终确认** ✗：`InstallProbe.unavailable` 把**超时**（`BlockingCall.bounded` 到点）
与**抛错**（`isAppInstalled` throw）**折叠成同一个值** ✗ ⇒ 日志里分不出是哪一种 ✗。
⇒ **已补诊断**（守卫 **R58**）：探测带**耗时**（超时贴近上限、抛错瞬时 ✓）＋
**再问同一个 ID 一次**（分开「瞬时失败」与「通道持续撒谎」✓）⇒ 下一份真机日志即可定性 ✓。

#### 5.2.2 ⚠️ **更正：阳性对照「单发」是刻意的，不是漏掉**（2026-09-20）

我先查到 `removeProfiles` 里两条路径待遇不同：

| 路径 | 服务 | 重试 |
|---|---|---|
| `dumpProfiles`（列描述文件） | misagent | ✅ 有界重试：`Provision.resetProvider()` ＋ 等 4 秒 × 3 次 |
| **阳性对照**（`isAppInstalled`） | installation_proxy | **单发** |

加上真机证据（两次中止同行都带 `dump 尝试 2/3 次` ⇒ 列描述文件那条路径**重试了 2–3 次才成功**），
我判断这是「**同一已知条件只给一条路径加防护**」（本仓已有 4 次前科），
并**打算照抄 `dumpProfiles` 给阳性对照加 reset ＋ 重试** ✗。

**⇒ 动手前读到 `probeInstalled` 上面那段注释，结论被推翻** ✓：

> **刻意不调 `Install.resetProvider()`**（虽然 `InstalledAppDeviceVerifier` 会调）：
> 本函数跑在「刚装完一个 App」与「自替换结算」两个时间点上，此刻可能有
> installation_proxy 连接正在服务，重置会把它拆掉（**R05**：同一个 Bundle ID 上
> 不能有两个并发 installd 命令）。缓存连接失效的代价**已经由阳性对照兜住** ——
> 那种情况下对照会抛错或答错，**直接中止整轮，方向是安全的**。

**⇒ 阳性对照「单发」是刻意的** ✓，而且**不 reset 正是为了不触发 R05** ✗。
两个调用点**语境不同**：`InstalledAppDeviceVerifier` 跑在**安装完成之后**（可安全重置 ✓），
而 `DeviceProfileCleaner` 跑在**安装前后**（重置会拆掉正在服务的连接 ✗）。

**⇒ 所以「启动早期那轮维护白跑」不是缺陷，是一个被明确接受过的取舍** ✓ ——
设计者已经算过：**缓存连接失效的代价 = 那一轮不回收（安全方向）** ✓。
⇒ **代码不动** ✓。本轮只保留诊断（探测带耗时 ＋ 再问一次 ✓，两者都不 reset ⇒ 不碰 R05 ✓）。

#### 5.2.3 📏 **实测结果（构建 177，`Seal-log(29).txt`）：瞬间抛错，不是超时**

诊断上线后拿到的真实数据（`10:27:45`，冷启动后 20 秒那一轮）：

| 探测 | 结果 | 耗时 |
|---|---|---|
| 阳性对照 第一次 | `.unavailable` | **2.4e-05 秒**（24 微秒） |
| 阳性对照 第二次 | `.unavailable` | **2.98e-06 秒**（3 微秒） |
| `com.apple.Preferences` | `.unavailable` | **2.98e-06 秒** |
| `com.apple.mobilesafari` | `.unavailable` | **2.98e-06 秒** |

**⇒ 三条结论：**

1. **不是超时** ✗（超时会是 ≈15 秒 = `BlockingCall.queryTimeoutSeconds`）⇒
   是 **`isAppInstalled` 立刻抛错** ✓；
2. **不是「只有 Seal 自己查不到」** ✗ —— **系统 App 也瞬间失败** ⇒ 是**整条查询**立刻不可用 ✓；
3. **同一轮里 `dump` 重试 2–3 次后成功** ✓ ⇒ 设备会话**部分可用**（misagent 能用、
   installation_proxy 立刻抛错）⇒ 不是「设备完全没连上」✗。

**对照**：4.5 分钟后（`10:32:12` 通道「正常」→ `10:32:25`）**同一轮维护完全正常** ✓ ——
⇒ **那个窗口是分钟级，不是秒级** ✗。

**⇒ 因此：**
- ❌ **加重试没用** ✗ —— 窗口是分钟级，几秒的重试覆盖不到 ✓；
- ❌ **加 reset 更不该做** ✗ —— 会拆掉正在服务的连接（R05）✓；
- ✅ **代码保持现状是对的** ✓ —— 设计者算过的取舍成立：**代价只是「启动早期那一轮不回收」** ✓，
  4 分钟后自然恢复 ✓。
- ⇒ 本轮**只修我自己引入的诊断 bug**（见 5.2.4）✓，**不改任何行为** ✓。

#### 5.2.4 🐞 我自己引入的诊断 bug：`description` 没生效（已修 + 已加守卫）

第一次拿到诊断时，日志里打出来的是：

```
第一次=TimedProbe(probe: Seal.ProfileReclaimPolicy.InstallProbe.unavailable, seconds: 2.40802764…812e-05)
```

**⇒ 我写的 `description` 没生效** ✗ —— Swift 的 struct 光有一个 `var description`
**不会**让字符串插值用它，插值走的是**合成的 memberwise 描述** ⇒
必须显式声明 **`: CustomStringConvertible`** ✓。而且那一行太长，被日志**截断**了 ✗
（`…` 在中间）⇒ **诊断反而把日志变难读了** ✗。

**⇒ 已修**（`struct TimedProbe: CustomStringConvertible` ✓）＋ **加了守卫 R58b** ✓ ——
这类「加了诊断、但诊断**静默降级成噪音**」的退化，**只有守卫能钉住** ✗。

#### 5.2.5 ⚠️ 教训：这一轮我**三次**结论没落在代码/数据上

| # | 我的错判 | 谁纠正的 |
|---|---|---|
| 1 | 「阳性对照挑错了 ID（用了旧 Team 后缀的 Seal 自己）」✗ | 读代码：用的是 `Bundle.main.bundleIdentifier` ✓ |
| 2 | 「重试漏覆盖（本仓第 5 次）」✗ | 读代码：**刻意不 reset 是为了不触发 R05** ✓ |
| 3 | 「零点几秒 ⇒ 抛错 ⇒ 只有 reset 能救」✗ | **实测数据**：微秒级瞬间抛错，而 4 分钟后**自然恢复** ⇒ 重试无用、reset 不该做 ✓ |

**⇒ 判据：**
- 判「这条路径漏了防护」之前，**先读那个函数上方 30 行的注释** ✓ ——
  本仓大量「看起来该统一、其实刻意不统一」的决定**都写在注释里** ✓；
  **读不到理由 ≠ 没有理由** ✗，按错的结论去改会**破坏一条已经想清楚的安全边界** ✗✗；
- 判「成因是什么」之前，**先把判据补到日志里、拿真实数据说话** ✓ ——
  前两次靠**读代码**纠正，第三次靠**实测数据**纠正 ⇒ **两种都要，缺一不可** ✓。

---



---

### 5.3 ⏸️ **已决定推迟：`cryptid` 清零**（用户 2026-09-20 选 B）

**背景**：换签名器后，`FairPlay cryptid` 不再被清零 ✗（老补丁 `b548021` 在 `rork-sign` 里，
49 行 ＋ 测试 ✓，提交信息里写着「对齐 ldid / zsign / Sideloadly」✓）。

**当时的两个选项**：

| | 做法 | 结论 |
|---|---|---|
| A | 发布前先做（在 Seal 自己的准备阶段清 `cryptid` ✓，**不碰上游** ✓） | ❌ 未选 |
| **B** | **先发 1.2.0，`cryptid` 留到下一版** | ✅ **用户选了这个** |

**选 B 的理由（我改推荐 B 的理由）**：
1. 这个改动**没有真机证据说明必要** ✗（用户实测抖音 657.6 MB ＋ LiveContainer 都正常启动 ✓）；
2. 而它动的是**签名路径** ✗ —— 写坏了会毁掉**每一个**签出来的包 ✗✗
   ⇒ 等于**用一个未验证的风险换一个未证实的风险** ✗；
3. 1.2.0 现在的状态是「**已验证、可发**」✓。

**⏭️ 下一版要做的**（已查清可行性 ✓，**不要从零摸索**）：
- **位置**：`SigningWorkspace.prepare` 的本地准备阶段（签名**之前** ✓）——
  必须早于 CodeDirectory 页哈希计算 ✓（`cryptid` 位于**被签名的代码区内** ✓）；
- **可复用的遍历**：`removeOldSignatures(in:)` 的 `enumerator` 已经**无条件全树访问每个文件** ✓
  ⇒ 把清 `cryptid` 折进同一趟 ✓（**不新增遍历** ✓）；
  ⚠️ 别指望「归一化」那趟 ✗ —— 它只收集 `_CodeSignature` 目录 ✗，不遍历 Mach-O ✓；
- **可复用的解析**：`Seal/Core/Import/IPAParserService.swift:418` 已有
  `LC_ENCRYPTION_INFO_64` → `cryptid` 的解析 ✓（含防畸形包的 `cmdsize >= 8` 守卫 ✓）；
- **要点**：`cryptoff`/`cryptsize` 不变、**只清 `cryptid@loadcmd+16`** ✓；无加密命令的镜像**行为不变** ✓；
  `cryptid=0` 时**不写**（no-op ✓）；
- **必须配**：合成 fixture ＋ 两个回归测试（`cryptid=1` 清零 / `cryptid=0` 保持 ✓）＋ 守卫 ✓；
- **验证**：**真机** —— 签一个 App 并点开 ✓（这是签名路径改动的唯一有效验收 ✓）。

---

## 六、没做的事（刻意）

- **没有**给上游代码打任何补丁 ✓（用户死命令「**不要打补丁**」✓）；
- **没有**重建签名缓存 ✗（上游没有 ⇒ 不发明 ✓）；
- **没有**改 `docs/qa/` 里的历史事故报告 ✓（那些是**当时**的记录，不改写历史 ✓）。

---

## 七、首次 CI 结果（run `35478381222`，提交 `3fdb4e1`）

| job | 结果 |
|---|---|
| `build-package` | ✅ **6m44s** —— **签名器整个换掉之后编译通过** ✓，产物 `Seal-174` ✓ |
| `swift-regression` | ✅ 9m13s —— 单测通过 ✓ |
| `signer-tests` | ❌ 2m50s —— `CodeSignKit` 那步**全绿** ✓；**`SideSign` 那步挂了** ✗ |
| `publish-release` | skipped（正常 ✓） |

**⇒ 结论：换签名器在编译与单测层面是成立的** ✓ —— 本机没有 Swift 工具链，
这是第一次真编译，通过了 ✓。**`Seal-174` 可以直接装真机测** ✓。

### 7.1 `SideSign` 那步为什么挂（**上游自己的缺陷**，不是我们改坏的）

```
SideSignTests.swift:35:13: error: cannot find 'FileManager' in scope
SideSignTests.swift:70:85: error: cannot find 'UUID' in scope
SideSignTests.swift:51:41: error: cannot infer key path type from context
```

⇒ 上游那个测试文件**根本没写 `import Foundation`** ✓（它的 import 只有
`Testing` / `@testable import SideSign` / `CodeSignKit` / `GSACryptoKit` ✓），
另有一处 `entries.map(\.filename)` 的 key path 推断失败 ✓
（**Swift 不支持从上下文推断这种 key path** —— 本仓技能里也记过同款 ✓）。

**⇒ 这个 job 是 2026-09-19 新加的 ⇒ 一跑就把它照出来了** ✓ —— 这正是门禁的价值 ✓。

### 7.2 处置：**收窄，不给上游打补丁**

剩下的 3 个用例测的是 `Device` 模型与 `Archive` 读写往返 ——
而 **Seal 完全不使用 `SideSign.Archive`** ✓（`grep` 为空 ✓），
`Device` 也是 SideSign 自己的模型（Seal 用 `ALTDevice` ✓）⇒ **对 Seal 零价值** ✓。

⇒ 按用户死命令「**不要打补丁**」⇒ **删掉那一步**（连同 `Tests/` 与 `Package.swift`
的 `.testTarget` ✓），**不给它加 `import Foundation`** ✗。
⇒ `signer-tests` 收窄为**只测 `Vendor/CodeSignKit`** ✓ —— 那才是签名内核，
而且它在这次 CI 里**已经全绿** ✓。守卫 R56 同步收窄 ✓。

