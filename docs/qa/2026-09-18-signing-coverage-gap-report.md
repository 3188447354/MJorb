# 「让 Seal 能签各种 IPA」——覆盖面审计与差距报告

- 日期：2026-09-18
- 触发：用户要求「全局查签不了这类…无论大包、小包、各种各样的情况都需要能成功签名，
  可以研究市面上所有签名工具的做法，以及上游的做法」
- 一手证据：用户提供的 `抖音.ipa`（**779,656,265 字节 / 5053 个文件 / 解压 1,463,494,972 字节**）
  + 构建 118 的真机日志 `Seal-log(14).txt`

> **结论先说**：签名引擎（上游 rork-sign）的覆盖面**比预期好**，
> 下面 10 项「各种 IPA 的硬骨头」它全都处理了。
> **这次签不上的真正成因不在引擎，在 Apple 侧限流**（详见
> [`2026-09-18-only-douyin-fails-real-chain.md`](./2026-09-18-only-douyin-fails-real-chain.md)）。
> 所以「让各种 IPA 都能签成功」的重点是**减少向 Apple 发的请求数**，
> 而不是继续加强本地签名。

---

## 一、抖音这个包到底特殊在哪（实测）

| 项 | 值 | 会不会挑战签名器 |
|---|---|---|
| 体积 | 779.6 MB（压缩）/ **1.46 GB（解压）** | 只是慢（本地解压/重签/打包 ≈ 112 秒） |
| 文件数 | **5053** | 资源封存要逐个哈希 |
| 主 App | `Payload/Aweme.app` | — |
| 扩展 | **8 个 `.appex`**（含 2 个 Widget、1 个 Broadcast、1 个 NotificationService…） | **决定要向 Apple 注册 9 个 App ID** |
| 框架 | **20 个 `.framework`** | 需逐个重签 |
| dylib | **4 个**，其中 **3 个是注入的第三方 tweak**：`DYKiller.dylib`、`Yuki.dylib`、`DYYY.dylib`（放在 **app 根目录**） | **最容易被签名器漏掉的一类** |
| 嵌套 `.app` / Watch | 无 | — |
| 其他 | `OnDemandResources.plist`、大量 `.bundle`（数百个） | — |

⇒ **需重签的 Mach-O 约 33 个**（1 主 + 8 扩展 + 20 框架 + 4 dylib）。

**这个包是「改包」产物**（注入了 3 个 tweak dylib）。改包 IPA 是签名器最容易栽的一类。

---

## 二、签名引擎覆盖面审计（逐项核过代码）

| 能力 | 覆盖 | 证据 |
|---|---|---|
| 嵌套 `.app` / `.appex`（含 identifier 重写、profile 嵌入） | ✅ | `AppBundleSigner.AppBundleIdentityRewriter`，`.app`/`.appex` 递归 |
| 嵌套 `.framework` / `.xpc` / `.bundle` | ✅ | `BundleCodeScanner.nestedBundles`（`nestedBundleExtensions`） |
| **app 根目录下注入的 dylib** | ✅ | `BundleCodeScanner.standaloneCodeFiles` 枚举 bundle 内**所有普通文件** + `MachOFile.isMachO`，跳过嵌套 bundle 与 `_CodeSignature`/`SC_Info`/`.dSYM` ⇒ `DYKiller.dylib` 这类**会被签** |
| Watch app（`Watch/`、`WKApplication`、watchOS 平台标记） | ✅ | `isWatchBundle` 三重判据 + 独立 profile 回退 |
| 加密二进制（App Store FairPlay） | ✅ | `IPAParserService.isEncryptedBinary` 解析 `LC_ENCRYPTION_INFO_64` 的 `cryptid`，**导入时**就拦 |
| dylib 注入 / 移除 | ✅ | `AppSigningOptions.dylibInjections` / `dylibLoadCommandsToRemove` + `BundleDylibEditor` |
| 扩展丢弃（免费账号不支持某能力时） | ✅ | `extensionsToRemove` / `allowDroppingExtensions` |
| entitlements 按账号能力过滤 | ✅ | `filteredAppIDEntitlements` |
| 路径安全（`..`、绝对路径、控制字符、盘符） | ✅ | `ArchivePathValidator` |
| 大包门槛（条目数 / 解压总量 / 元数据 / 图标） | ✅ **宽松** | `ArchiveLimits`：50,000 条目 / 8 GB 解压 / 2 MB 元数据 / 20 MB 图标 —— 抖音 5,053 / 1.46 GB，**远低于** |
| 多团队 profile 混用拒绝 | ✅ | `AppProvisioningAssets.validateTeams` |
| profile 未授权该 Bundle ID 拒绝 | ✅ | `validateAuthorization` |

**⇒ 引擎侧没有发现「按构造签不了」的缺口。**

---

## 三、Seal 自己设的门槛（逐条核过数值）

| 门槛 | 值 | 判定 |
|---|---|---|
| IPA 条目数 | 50,000 | ✅ 不会误拦 |
| 解压总量 | 8 GB | ✅ 不会误拦 |
| 元数据 / 图标单文件 | 2 MB / 20 MB | ✅ |
| **磁盘空间** | **`IPA × 4 + 200MB`** ⇒ 抖音需 **3.32 GB** | ⚠️ **大包的真实门槛**（实测峰值需求 ≈ 3.0 GB，数值本身合理，但对剩余空间少的机器是硬拦） |
| 单请求超时 | 20 秒（描述文件 30 秒） | ⚠️ Apple 慢时 Seal 主动放弃，而**超时不属于「会话过期」，不会退避重试** |
| 扩展默认不可丢弃 | `allowDroppingExtensions` 默认 false | ⚠️ 任一扩展失败 ⇒ 整个 App 失败（**安全设计**，有用户确认通道） |
| 证书剩余寿命须覆盖 7 天 | `SEAL-CERT-229` | ⚠️ 设备时钟不对时触发；Apple 正常发的是 1 年期证书 |
| `Payload/` 下必须恰好 1 个 `.app` | `SEAL-IPA-103` | ⚠️ 多 App 的 IPA 直接拒绝（罕见） |
| 本地预检「存活 App ID ≥ 10 就拦」 | **已删除** | ✅ 不再是限制 |
| 请求最小间隔 | 0.4 秒 | ✅ 只是下限 |

---

## 四、真正的瓶颈：**向 Apple 发的请求数**

这是「扩展多的 App 签不上」的根因，也是唯一有实测证据的成因。

一次抖音签名的请求账（Phase 1 每个 bundle ID **2 次写**）：

| 阶段 | 每个 bundle ID | 抖音（9 个） |
|---|---|---|
| Phase 1 | `addAppID`（缺才发）+ **`updateFeatures`（有 entitlements 就必发）** | 最多 **18** |
| Phase 2 | `fetchProvisioningProfile`（内部可能还 `deleteProvisioningProfile`） | **9–18** |
| 证书 / 设备 / 团队 | 一次性 | ~5 |
| **合计** | | **约 32–41 次** |

**对照实测**：同一份日志里三次**成功**的签名（Seal 自续签 / LiveContainer / 3105）
名额诊断全是「**需新注册 0 个**」—— 即一个 App ID 都没新建、请求量小；
而抖音要新建 9 个 ⇒ 撞上限流。

### 已排查过的「减请求」机会

| 想法 | 结论 |
|---|---|
| 跳过「App ID 已存在且 features 未变」的 `updateFeatures` | ❌ **不做**：`ALTAppID.features` 在代码里**只被写入、从未被读取**，无法证明 `fetchAppIDs` 会填充它 —— 靠它跳过会**静默丢掉 entitlements** |
| 描述文件已有效则复用 | ❌ 无净收益：判断「已有效」本身就要先拉一次列表 |
| 延长请求间隔（0.4 秒 → 更大） | ⏸ **先取证再调参**：本次日志证明账号被限流，但证明不了「0.4 秒太密」 |

---

## 五、结论与下一步（按优先级）

**已经做完的（本轮）**
1. `sign()` 不再把「限流」覆盖成「去重新验证」—— 掐掉死循环（R31）
2. `fetchAppIDs` 过退避重试 + Phase 1 入口先留痕（R31）
3. 证书列表拉取失败记原因与耗时（R31）
4. **进度文案不再撒谎**：解压 780 MB 的包不再显示「正在验证 Apple ID」（R32）
5. `prepare()` 的耗时写进日志（R32）

**建议的下一步（需要新证据或明确收益）**
| 优先级 | 事项 | 依据 |
|---|---|---|
| 高 | **减少 Phase 1 的 `updateFeatures` 次数** | 占抖音请求量的一半。需要先确认 `fetchAppIDs` 是否回填 `features`（可在真机日志里加一条诊断验证） |
| 高 | **让「超时」也可重试（仅读操作）** | 读操作幂等；限流时 Apple 响应变慢，超时后直接失败太脆 |
| 中 | **磁盘门槛按实际解压量估算**（而不是 `压缩体积 × 4`） | 高度可压缩的 IPA 会被低估 |
| 中 | **多 `.app` 的 IPA 不再直接拒绝** | 目前 `SEAL-IPA-103` 硬拒 |
| 低 | 请求量诊断（本次签名预计发 N 次） | 便于事后归因 |

---

## 六、诚实记录：本报告没有覆盖的

- **市面工具的逐条对照没有做到「研究所有」**：网页检索产出偏低（多是入门教程），
  真正有价值的一手材料是**上游 `Vendor/rork-sign` 的源码与测试**（已逐项读过），
  以及 Seal 自身的导入/签名链路。Sideloadly / ESign / Feather / Scarlet 的内部做法
  **没有拿到可信的一手材料**，因此本报告没有引用它们的具体实现，**不编造对照**。
- **超时重试、请求量削减**都还是「建议」，不是已验证的结论 —— 需要下一份真机日志。
