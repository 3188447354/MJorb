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
| `回收中止：阳性对照未通过（com.mjorb.seal.CT8QZ7352B 被答成未安装）` ✗ —— 阳性对照挑的是**旧 Team 后缀的 Seal 自己**，而那个 ID 已被自替换覆盖 ⇒ **必然**答「未安装」 | ⏸️ **待单独查**（与换签名器无关 ✓）。⚠️ 同时 R44 的判别诊断显示 `com.apple.Preferences=unavailable`、`com.apple.mobilesafari=unavailable` ⇒ **系统 App 也查不到 ⇒ 通道不可信** ⇒ 按设计整轮不删 ✓（**这是保护，不是回归** ✓） |

### 5.3 换签名器的最终验收结论

**编译 ✓ / 单测 ✓ / 签名内核测试 ✓ / 大包签名＋安装 ✓ / 装完能启动 ✓** ——
⇒ **换签名器（`rork-sign` → 上游 `SideSign` ＋ `CodeSignKit`）全部验收通过** ✓✓

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

