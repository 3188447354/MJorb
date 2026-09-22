# 大包签名耗时：归因现状审计（「112 秒」到底花在哪）

- 日期：2026-09-18
- 触发：讨论「市面上的签名工具如何做到签大体积 IPA 又快又成功」后，深入 Seal 自己的
  签名链路，核对「快」这件事在本地是否可测、可归因
- 方法：**只读代码**（未改任何 `Seal/**` 文件，未跑真机）。所有结论标注证据位置
- 一手数据来源：[`2026-09-18-signing-coverage-gap-report.md`](./2026-09-18-signing-coverage-gap-report.md)
  的实测（抖音包 + 构建 118 真机日志）

> **结论先说**：本地签名链路**当前无法归因**。日志里唯一的本地耗时数字
> （「应用文件准备完成（解压/改写/重签/打包），耗时 112 秒」）**既不含重签、也不含打包** ——
> 而那两步恰好是最可能最慢的。所以在补埋点之前，任何「优化大包签名」的动作都是盲改。

---

## 一、实测基线（构建 118，真机）

| 项 | 值 |
|---|---|
| 抖音 IPA | 779,656,265 字节（压缩） / **1,463,494,972 字节（解压）** |
| 文件条目 | 5,053 |
| 需重签的 Mach-O | **约 33 个**（1 主 App + 8 `.appex` + 20 `.framework` + 4 `.dylib`） |
| 主 App 根目录注入的 dylib | 3 个（`DYKiller.dylib` / `Yuki.dylib` / `DYYY.dylib`） |
| **`prepare()` 实测耗时** | **112 秒** |
| 对照 | 3105（4.3 MB）、LiveContainer（4.9 MB）都是秒级 |

⇒ 「只有抖音卡」的直接原因是**包大**，不是账号、不是限流（这个结论已在上游报告里立住）。

---

## 二、签名链路的真实阶段划分（逐段核过代码）

Seal 的本地签名链路**不是**「对 IPA 签名」，而是「**解压成目录 → 对目录签名 → 重新打包**」：

| # | 阶段 | 实现位置 | 有耗时埋点？ |
|---|---|---|---|
| 1 | 读中央目录 + 安全校验 + 空间判断 | `SigningWorkspace.prepare`（`SigningWorkspace.swift:28-48`） | ✅ 含在 112 秒内 |
| 2 | **解压** | `FileManager.unzipItem`（`SigningWorkspace.swift:51`，系统流式 API） | ✅ 含在 112 秒内 |
| 3 | 结构改写（BundleID / URL scheme / UTI / 显示名 / 图标 / 删 Watch·AppClip / 清 `SC_Info` / 清注入残留 / 删空目录） | `SigningWorkspace.swift:70-104` | ✅ 含在 112 秒内 |
| 4 | **瘦身**：剥离 arm64e | `stripArm64eArchitecture`（`SigningWorkspace.swift:865-974`） | ✅ 含在 112 秒内 |
| 5 | **归一化**：根目录 framework/dylib → `Frameworks/` + 改写 `@executable_path` | `normalizeRootFrameworksIntoFrameworksDirectory`（`SigningWorkspace.swift:758-809`） | ✅ 含在 112 秒内 |
| 6 | 删旧签名 | `removeOldSignatures`（`SigningWorkspace.swift:666-681`） | ✅ 含在 112 秒内 |
| 7 | **重签**（33 个 Mach-O） | `RorkAppSigner.signAppBundle`（`RorkAppSigner.swift:61`）→ `RorkSigner.signBundle` | ❌ **无** |
| 8 | **打包**（1.46 GB → deflate） | `SigningWorkspace.package`（`SigningWorkspace.swift:151-167`） | ❌ **无** |

调用点（`ApplePortalSigningService.swift`）：

```
:682   prepare(...)                        ← 计时起止在这里（:681 / :692）
:692   「…（解压/改写/重签/打包），耗时 N 秒」  ← 文案与实际范围不符，见发现 1
:776   signingWorkspace.package(...)       ← 打包：无计时
:2401  RorkAppSigner.signAppBundle(...)    ← 重签：无计时
```

---

## 三、三个具体发现

### 发现 1 — 日志文案与代码范围不符（会误导排障）

`ApplePortalSigningService.swift:691-693` 写的是：

> `签名：应用文件准备完成（解压/改写/重签/打包），耗时 112 秒`

但 `prepare(...)` 的返回点是 `SigningWorkspace.swift:138`，它**只做了阶段 1–6**。
**重签（阶段 7）与打包（阶段 8）在它之后、且不在这个计时窗口内。**

⇒ 后果有两层：
1. **这个 112 秒不能被当作「签名总耗时」**，用户看到的本地等待时间明显更长；
2. 排障时会把它误读成「四件事加起来 112 秒」，从而**去优化解压**，而真正可能的大头
   （1.46 GB 的 deflate 打包）**根本没被计时**。

这与本仓已有的规矩直接冲突：**文案里凡是「已经帮你做了什么」的说法，都要在代码里找到那件事真的做了**。

**修法**：文案去掉「重签/打包」，改成「解压与结构改写」；或者（更好）补齐阶段 7、8 的计时后
再写「合计」。**在补齐之前，至少不能让它声称包含了没做的事。**

### 发现 2 — `normalizeRootFrameworks` 会把全树每个文件整体读进内存

`SigningWorkspace.swift:805-808`：

```swift
for case let url as URL in enumerator {
    guard url.isFileURL else { continue }
    try? rewriteExecutablePathReferences(machOURL: url, movedNames: movedNames)
}
```

而 `rewriteExecutablePathReferences` 的第一件事（`:825`）是：

```swift
guard var data = try? Data(contentsOf: machOURL) else { return }
```

**magic 判断（`u32(0) == 0xfeedfacf`，`:831`）发生在整个文件已经读完之后。**

- **触发条件**：`movedNames` 非空，即 `.app` 根目录存在 `.framework` / `.dylib`。
  **抖音正好满足**（3 个注入 tweak dylib 放在 app 根）⇒ 这个包会走进去。
- **代价**：对 5,053 个文件逐个完整读取（合计 ≈ 1.46 GB 磁盘读 + 同等量级的逐文件内存分配），
  其中**非 Mach-O 的那绝大部分读取是纯浪费**。
- **风险不止是慢**：单个大资源文件（几百 MB 的 `Assets.car` / 视频）会让内存峰值显著抬高，
  在 iOS 上存在被 jetsam 杀掉的余地。

**修法（低风险）**：先用 `FileHandle` 读前 8 字节判 magic，只有命中 `0xfeedfacf`（以及必要时
判断是否含 `@executable_path/Frameworks` 字面量）才整体读入。行为完全不变，只是不再读无关文件。

### 发现 3 — 引擎全串行，且签名缓存已实现但未启用

| 项 | 现状 | 证据 |
|---|---|---|
| **并行度** | **零并发** —— `Vendor/rork-sign/Sources/RorkSign/**` 内没有 `Task` / `DispatchQueue` / `concurrentPerform` / `withThrowingTaskGroup` | 全目录正则扫描无命中 |
| **签名缓存** | 已实现（按内容寻址缓存**已签名的 Mach-O**，key 覆盖 bundleID / entitlements / info.plist / 资源目录 / 证书 / CD 哈希模式），有单测与 README 示例 | `BundleSignatureCache.swift`、`BundleSigningTests.swift:280,307,329` |
| **缓存启用** | ❌ **`SigningCacheOptions` 在 `Seal/` 下出现 0 次** —— Seal 侧调用 `signBundle` 时没有传缓存目录 | 全仓 grep |
| **哈希次数** | `codeDirectoryHashingMode: .compatible` = **SHA-1 主 CD + SHA-256 备用 CD** ⇒ 每个文件算**两遍**哈希 | `RorkAppSigner.swift:110-112` |

- 33 个 Mach-O 串行签：**行为正确**（inside-out 顺序是必须的），但**同一层内**的
  framework / dylib 之间没有依赖，理论上有并行空间。
- 缓存未启用 ⇒ **续签同一个 App 也要从零重算**（对「7 天续签」这个主场景是稳定的浪费）。
- 双哈希是**兼容性权衡**（注释写明「单 SHA-256 CD 在部分老系统上校验更易失败」），
  **不是缺陷**，记录在此是为了说明「哈希时间天然是单份的两倍」。

---

## 四、与「市面工具做法」的对照修正（**包含对本轮讨论的一处纠错**）

讨论「市面工具如何签大包又快」时给出的杠杆，逐条对回 Seal 的真实实现：

| 杠杆 | Seal 现状 | 判定 |
|---|---|---|
| **不重压缩（zip store）** | ❌ **明确不做**：`package` 用 `.deflate`，注释给出真机证据 —— store-mode ZIP 会让 installd / CoreDevice 报 `MissingPackagePath` | ⚠️ **我上一轮的建议在 Seal 上不成立**，见下 |
| **zip 层增量重写（O(改动量)）** | ❌ 走「全解压 → 全打包」 | 有空间，但需替换 zip 实现 |
| **thinning（只留 arm64）** | ✅ **已有**：`stripArm64eArchitecture` 保留 arm64、丢弃 arm64e 及其它架构（仅 fat 二进制；thin arm64e 刻意不处理） | 已落地 |
| **不用 `--deep`** | ✅ 不适用（自研引擎，天然 inside-out） | 已落地 |
| **并行 codesign** | ❌ 全串行 | 有空间 |
| **复用未变资源的哈希** | ❌ **没做**：`removeOldSignatures` 先删掉 `_CodeSignature`，`CodeResourcesBuilder.write` 再全量重算 | 有空间，但注意删除顺序决定了旧哈希已不可得 |
| **签名结果缓存** | 🟡 引擎已实现，**Seal 未启用** | **成本最低的收益点** |

> **⚠️ 纠错（重要）**：我上一轮说「用 store 不压缩是收益最大的杠杆」，**这条对 Seal 是错的**。
> `SigningWorkspace.package` 的注释记录了真机结论：**store-mode ZIP 会导致 installd 定位/解压失败
> 并误报 `MissingPackagePath`**，而 jas / 爱思 / AltStore / SideStore 的标准 IPA 全部用 deflate。
> ⇒ 「压缩」在这里**不是可选的性能开关，而是兼容性要求**。
>
> 顺带一个**尚未验证**的推论：注释针对的是**整包 store**。zip 允许**逐条目**选择压缩方式，
> 而 IPA 里的大头（`Assets.car` / png / mp4 / 音频）本身已是压缩格式，deflate 收益接近 0
> 而 CPU 代价满额 —— 理论上「已压缩格式用 store、其余 deflate」能省掉大部分压缩时间，
> 且整体仍是 deflate IPA。**但这只是推论，没有真机证据，且需要替换 zip 写入实现**
> （`FileManager.zipItem` 只接受一个全局 `compressionMethod`）。**不要未经实验就动手。**

---

## 五、待验证的推测（**明确标注为推测，非结论**）

1. **打包可能是单项最大耗时**。1.46 GB 数据走 zlib deflate，移动端单核经验值约 20–50 MB/s
   ⇒ 量级落在 **30–70 秒**。**这是估算，没有任何实测支撑** —— 必须靠补埋点验证。
2. **阶段 4/5 的全树遍历可能占 10–30 秒**。`stripArm64eArchitecture` 对每个文件
   `FileHandle` + 读 8 字节；`normalizeRootFrameworks` 对每个文件整体读入（见发现 2）。
   两者都遍历 5,053 个文件，且**互相独立地各遍历一次**。
3. **阶段 1 的中央目录被读了两遍**：`requiredTemporarySpace(forIPAAt:)`（前置检查）与
   `prepare` 内部各开一次 `Archive`。5,053 条目的解析开销不大，但属可回收的重复。

---

## 六、下一步（按「先取证再优化」排序）

**A. 让 112 秒可归因（最小改动，最高价值）**
1. 修正 `ApplePortalSigningService.swift:692` 的文案 —— 去掉它并未包含的「重签/打包」；
2. 给**重签**（`:2401`）加耗时；
3. 给**打包**（`:776`）加耗时。

做完这三步，本地耗时会拆成「解压 / 结构改写 / 瘦身+归一化 / 重签 / 打包」五个数，
**优化方向由数据决定**，而不是由推测决定。

**B. 拿到数据后再选（每项都需先有证据）**
| 候选 | 前置条件 | 预估收益 |
|---|---|---|
| 启用 `SigningCacheOptions`（续签场景） | 确认缓存目录选点与磁盘占用策略 | 续签同一个 App 时省掉全部重签 |
| 修发现 2 的「先读后判 magic」 | 无（纯读法优化，行为不变） | 阶段 5 从「读整个包」降到「读每个文件的 8 字节」 |
| 同层 Mach-O 并行签名 | 需确认 rork-sign 的线程安全边界 | 33 个 Mach-O 串行 → 受限并行 |
| 逐条目压缩策略（见第四节纠错） | **必须先做真机实验**验证 installd 接受混合模式 | 打包时间大幅下降 |

**C. 不要做的**
- 不要在没有埋点数据的情况下调 deflate 参数或换 zip 实现 —— 这正是本仓反复强调的
  「先调参后取证」的反面。
- 不要把「112 秒」当成「大包签名总耗时」写进任何面向用户的文案或诊断结论。

---

## 七、本报告没有做的事（诚实边界）

- **没有真机实测**：本机无 Swift 工具链、无 iOS 设备，全部结论来自读代码。
  第五节的三条推测**都未被验证**。
- **没有改动任何 `Seal/**` / `SealTests/**` 文件**，因此没有触发守卫与 CI。
- **没有测量各阶段的真实占比** —— 这正是本报告主张先补埋点的原因。

---

## 八、补充：同一轮里并行落地的部分（2026-09-18 12:10–12:20）

本报告写完之后、提交之前，工作区里出现了**另一组并行改动**
（`ApplePortalSigningService.swift` / `SigningWorkspace.swift` / `Scripts/verify-release-safety.py` 等）。
它们把第六节 A 组的三项**都做了**，做法与本文的判断一致：

| 本报告的建议 | 并行落地的实现 | 位置 |
|---|---|---|
| 修正 `:692` 文案（去掉并未包含的「重签/打包」） | ✅ 改成「解压 + 结构改写；重签与打包另计」，并同步更新了守卫断言 | `ApplePortalSigningService.swift:688-697` |
| 给**重签**加耗时 | ✅ `resignStartedAt` 包住 `Task.detached { … }.value` —— 计时放在 detached **外面**，与本文的判断一致 | 同文件 `:2341-2345` / `:2425-2431` |
| 给**打包**加耗时 | ✅ `packageStartedAt` 包住 `package(...)` | 同文件 `:778-790` |
| 修第三节发现 2（先读 magic 再整体读入） | ✅ 读 4 字节判 `0xfeedfacf`，`defer` 关闭句柄，**行为不变** | `SigningWorkspace.swift:822-855` |

⇒ **第三节的发现 1 与发现 2 已经修复**；第四节的对照表里「thinning 已落地」一条不变。

### 仍然缺的：112 秒**仍未分段**

并行改动修正了**文案**（不再声称包含重签/打包），但 `prepare(...)` 内部的 112 秒
**仍然只有一个总数** —— 解压 / 结构改写 / 剥离 arm64e / 归一化 / 收尾各占多少，
日志里依旧看不出来。发现 2 的修复会显著降低「归一化」那一段，但**降了多少、
剩下的大头是解压还是别的，仍然回答不了**。

⇒ 真正剩下的缺口是**分段计时**。落地形态（本轮已设计、未落地）：

- 新增 `SigningPrepareTiming`（`scanSeconds` / `unzipSeconds` / `rewriteSeconds` /
  `slimSeconds` / `finalizeSeconds`）；
- 随 `PreparedSigningWorkspace` 返回（**给默认值**，避免破坏构造点 —— 全仓只有 1 处）；
- 由 `:697` 那条日志一并打印，形如
  `签名：应用文件准备完成…，耗时 112 秒（扫描 1 / 解压 45 / 结构改写 12 / 瘦身 30 / 收尾 24）`。

⚠️ 分段计时**必须**在 `prepare` 内部打点（`ApplePortalSigningService` 看不到它内部的分段），
而 `prepare` 是同步 `throws` 函数、`SigningWorkspace` 没有 logger
⇒ 用返回值带出来是侵入最小的做法。
