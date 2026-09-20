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

## 五、🔴 待真机验证（换签名器带来的三个已知风险）

1. 🔴 **装完能不能启动** —— 上游**不处理 FairPlay `cryptid` 清零** ✗
   （`CodeSignKit/MachOParser.swift:555` 只有「读」✓，`SideSign` / `SideStore` 也完全不处理 ✓）
   ⇒ 原文照录：「*a decrypted image that still advertises cryptid=1 makes dyld attempt
   FairPlay decryption with the wrong account and **crash at launch***」✗✗
   ⇒ **这是最高严重级** ✓。若真的启动崩，把原型补丁（`Vendor/rork-sign` 历史提交 `b548021` ✓）
   移植到 `CodeSignKit` ✓。
2. 🔴 **大包还会不会被 CPU 预算杀掉** —— 没有签名缓存 ⇒ **全量重签** ✗
   （iOS 硬限制：**任意 180 秒窗口内 CPU 时间 ≤ 90 秒**；构建 147 实测 90 秒 / 166 秒 ⇒ 被杀 ✗）
   ⇒ 必须用**抖音**（780 MB ＋ 8 扩展）验证 ✓。
3. 🟡 **日志里还能不能看出「死在哪个 bundle」** —— 逐 bundle 诊断没了 ✗
   ⇒ 若再被 CPU 预算杀掉，考虑接上游 `signApp(progress:)`（**上游自己的 API** ✓，不算发明 ✓）。

---

## 六、没做的事（刻意）

- **没有**给上游代码打任何补丁 ✓（用户死命令「**不要打补丁**」✓）；
- **没有**重建签名缓存 ✗（上游没有 ⇒ 不发明 ✓）；
- **没有**改 `docs/qa/` 里的历史事故报告 ✓（那些是**当时**的记录，不改写历史 ✓）。
