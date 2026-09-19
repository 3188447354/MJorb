# 上游对齐（Seal 是二开，必须跟上游）

- 建立：2026-09-19
- 依据：`AGENTS.md` 第 1 节「改动前自查清单」**第 5 条** ——
  「上游是否已有 —— Seal/AltStore/SideStore/jas/zsign 已有等价实现则**优先对齐/复用**，不自造轮子」
- 起因：用户指出「**seal 就是二开上游的，当然需要上游已经实现的方法**」✓

---

## 一、上游是谁（用户 2026-09-19 明确）

**上游 = AltStore + SideStore** ✓

两者的关系：**SideStore 是 AltStore 的 fork**，官方描述是
> *"SideStore is a fork of AltStore that doesn't require an AltServer."*（AGPL-3.0，6.5k stars）

**⇒ 这句话和 Seal 的定位一字不差** ✓（设备内签名 + LocalDevVPN，不需要电脑）
⇒ **SideStore 是更近的上游**，它的做法比 AltStore 更有参考价值 ✓

### 补充：另外两类「上游」

| 上游 | 关系 | 处置 |
|---|---|---|
| **`rorkai/rork-sign`** | **内置源码**（`Vendor/rork-sign/`，Apache-2.0） | 同步时要**保住 Seal 的补丁** ✓（见第三节） |
| **`rileytestut/AltSign`** | **SwiftPM 依赖**（`ALTAppleAPI` / `ALTTeam` / `ALTCertificate`） | 跟版本号 + 对照**用法** ✓ |

---

## 二、为什么不能靠 `git merge upstream`

Seal 的 git 历史**被重建过** ✗：全部 659 个提交都是同一个作者（`Seal Developer`），
**历史里没有上游的任何提交** ⇒ 与上游**没有共同祖先** ⇒ `git merge` / `git rebase` **不可用** ✗。

⇒ **只能做「语义对照」**：把上游的关键文件拉下来读，
对照的是**做法**而不是文本（语言/结构/框架都不同，文本 diff 没有意义 ✗）。

---

## 三、`Vendor/rork-sign/` 的补丁清单（覆盖上游时必须保留）

Seal 改过它 ✗ —— 每次同步上游前先确认这些补丁仍在（守卫已钉 ✓）：

| 补丁 | 守卫 |
|---|---|
| 判 Mach-O 时**不许整块读入**（`.mappedIfSafe`） | R37 / R49 |
| 读可执行文件用 mmap（`readEntitlementsXML` 两条链路 + 签名主路径 + host 校验 + 缓存条目） | R50 |
| 签名缓存必须真的传进去 | R38 |

---

## 四、对照台账（**改签名/续签链路前先查这里**）

> 规矩：**对照过就记一条** —— 免得同一个问题重复查 ✓。
> 结论分两种：**「跟」（上游更对 ✓）** 与 **「不跟」（Seal 已更好 / 上游没有 ✓）**。

| 日期 | 对照对象 | Seal 侧 | 上游做法 | 结论 |
|---|---|---|---|---|
| 2026-09-19 | **anisette 的取用时机** | `signOnce` 取一次、用一整轮 ✗ | AltStore `AppManager`：本地打补丁**之后**、第一个 Apple 请求**之前**刷新，并**显式声明依赖** | **跟** ✓ → 已修（`921fa4e`）；因 Seal 的 Apple 窗口更长（9 个 App ID × 2 次写 ✗），**加了更多刷新点**（`83084d0`） |
| 2026-09-19 | **证书轮换的撤销判据** | **必须 `sealSignerConfirmed`** ✓ + 撤销后**立刻持久化、立刻重建、成功即停** ✓ | AltStore 只看 `machineName` 前缀是否 `"AltStore"` | **不跟** ✓ —— Seal 的判据更严、顺序更谨慎 |
| **2026-09-19** | **证书的整体策略（顺序 / 谁来撤）** | **先撤销旧证书、再创建** ✗ —— 撤销成功但创建失败 ⇒ **账号变 0 张证书** ⇒ 用它签过的 App 全部打不开 ✗✗ | **SideStore `CertificateProvisioningFlow`**：<br>① 先找活跃证书/embedded 复用 ✓<br>② 否则**先尝试创建** ✓<br>③ 创建失败才进 `replaceCertificate`：候选 = `name` 含 `ios development`/`iphone developer` ✓；**弹窗让用户选** `keepExisting`（不撤，直接再试 ✓）/ `revokeSelected` ✓<br>⇒ **「先创建」⇒ 不存在「撤了没建成」的窗口** ✓✓ | **跟** ✓ —— 按用户指示「**Seal 比 SideStore 严格就去除，按 SideStore 来**」<br>⇒ 改成「**先创建；失败才处理撤销，且由用户选**」<br>⇒ **顺带消灭「0 张证书」这个灾难** ✓✓<br>**已实施 `ff718d9`** ✓（**自动撤销能力保留** ✓ —— 撞 3022 后仍自动撤销 + 重建）<br>⚠️ 那条既有守卫的文案本就写着 **`or`**（「rotate before a free-team request **or** after exact 3022」），实现却写成 `and` ✗ ⇒ 按意图更新 ✓ |
| **2026-09-19** | **扩展的 App ID 准备顺序** | 主 App **排最前** ✓（`ApplePortalAppIDResolver.preparationOrder`）；扩展**串行**、且每请求**节流 0.4 秒**（`AppleRequestThrottle`）✗ | SideStore `FetchProvisioningProfilesOperation`：<br>① **主 App 先准备** ✓（`provisionAndFetchProfile(for: targetAppBundle, parentAppBundle: nil)`，在扩展之前）<br>② 扩展用 **`withThrowingTaskGroup` 并发** ✓<br>③ **没有节流** ✓<br>（`PrepareAppExtensionBundleIDsOperation` 只做「扩展 BundleID 跟着主 profile 改写」✓，不涉及注册顺序） | **一半一致、一半待定**：<br>① **主 App 先 = 上游一致** ✓ ⇒ **不用改** ✓；<br>② **串行 + 节流 vs 并发无节流** ✗ ⇒ **待定** —— 节流是为「1100 短时频率限制」加的 ✓，<br>但**本轮的 anisette 修复可能才是 1100 的真因** ✗（gap 前成功 / gap 后失败的时间线支持这点 ✓）<br>⇒ **建议先跑一次带 anisette 修复的构建**：若不再 1100 ⇒ 再考虑去掉节流、改成并发 ✓<br>（并发还能**缩短 Apple 窗口** ⇒ 对 anisette 寿命有利 ✓✓） |
| — | **证书轮换 / 更新** | `ApplePortalCertificateService` 的轮换事务 | **待对照**：SideStore `UpdateAppCertificateOperation.swift` + `VerifyCertificateOperation.swift` | **待对照** |
| — | **描述文件批量安装** | 逐个安装 | **待对照**：SideStore `RefreshAppOperation` 里有**批量 profile 注入**（`addPendingProfileBatch`） | **待对照** |

---

## 五、SideStore 流水线的对照入口（27 个操作，按相关度排序）

SideStore 的签名/刷新是一条**显式流水线** ✓（`SideStore/Core/Operations/PipelineOperations/`）：

| 与 Seal 的哪个问题相关 | SideStore 的操作 |
|---|---|
| **证书轮换**（「0 张证书」风险区） | `UpdateAppCertificateOperation` / `VerifyCertificateOperation` / `CacheSigningCertOperation` / `EmbedSigningCertOperation` |
| **扩展的 App ID**（Seal 写死顺序 ✗） | `PrepareAppExtensionBundleIDsOperation` / `RemoveAppExtensionsOperation` |
| **Apple 请求窗口**（anisette 寿命） | `FetchProvisioningProfilesOperation` |
| **安装 / 上传** | `StageAppOperation` / `SendAppOperation` / `InstallAppOperation` / `CleanStagedAppOperation` |
| **自定义名称 / 图标** | `UserCustomizationOperation` / `ChangeAppIconOperation` |
| **前置检查** | `PreflightChecksOperation` |

另外 SideStore 把 anisette 单独做成一个模块 ✓：
`SideStore/Core/Anisette/{AnisetteProvider, OnDeviceAnisetteManager, AnisetteServersManager}.swift`
（Seal 对应 `AnisetteClient` / `AnisetteServerStore` ✓ —— 命名都几乎一样 ✓）

---

## 六、怎么执行（每次改签名/续签链路之前）

1. **查台账**（第四节）：有相关条目 ⇒ 直接用结论 ✓；
2. **没查过** ⇒ 用下面第七节的命令把上游对应文件拉下来读；
3. **读完写台账** ✓（一行：日期 / 对象 / 两边做法 / 跟或不跟 ✓）；
4. **如果「跟」** ⇒ 按 Seal 的结构改造（**不是照抄** —— 语言与结构不同 ✓）；
5. **跑守卫** ✓（守卫是「本仓已踩过的坑」的沉淀 ✓）。

---

## 七、拉取上游文件（`gh` 已登录）

```bash
# AltStore
gh api "repos/altstoreio/AltStore/contents/<路径>" --jq '.content' | base64 -d

# SideStore
gh api "repos/SideStore/SideStore/contents/<路径>" --jq '.content' | base64 -d
```

落盘建议放 `build/upstream/`（`build/` 不进版本库 ✓）。

---

## 八、不要对齐的部分（Seal 独有，别去「跟」）

- 免费账号 **App ID 名额**与主 App/扩展的**准备顺序**策略；
- **设备端描述文件回收**（含「扩展随父保留」的判定）；
- 「**两张表同源**」「**同一规则只落一条链路**」这类本仓历史坑的守卫；
- 自替换 / 续签事务（`SelfReplacementTransaction`）；
- 本地准备的**分段时间日志**（解压 / 改写 / 瘦身 / 归一化 —— 为 CPU 预算服务 ✓）。
