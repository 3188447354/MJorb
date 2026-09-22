# 远程配对（RPPairing）支持的系统版本 —— 精确到小版本

> 查证日期 **2026-09-20**；结论有效期取决于 Apple 是否改变 `CoreDeviceProxy` 的可用版本。
> 复核方法见文末 —— **别把它当永久真理**。

## 一、结论

**远程配对（RPPairing）需要 iOS / iPadOS 17.4 或更高版本。**

分界线的成因：远程配对要走 Apple 的 **`CoreDeviceProxy`** lockdown 服务，**这个服务是 iOS 17.4 才引入的**。
iOS 17.0–17.3.1 上没有它，userspace 隧道只能经 Wi-Fi/bonjour 走 RemotePairing
⇒ **配对助手在 USB 上生成不了远程配对文件**（这正是 Seal 的唯一用法）。

## 二、判据来源（两处互相独立）

| # | 来源 | 原文 / 要点 |
|---|---|---|
| 1 | 固定上游 `idevice_pair` **0.1.14**（commit `e3abb34`）README | *"Select pairing mode, `RPPairing` for **iOS 17.4+**, `Lockdown` for older verions"*（拼写是上游原文） |
| 2 | pymobiledevice3 文档《iOS 17+ tunnels》 | *"iOS 17.4+ … uses the CoreDeviceProxy lockdown service"*；17.0–17.3.1 *"predate the CoreDeviceProxy service"* |

代码级佐证：上游 `src/main.rs` **没有任何版本判断** —— 配对类型由用户手动单选
（`PairingMode::Lockdown` / `PairingMode::RemotePairing`），默认值是硬编码的 `RemotePairing`。

## 三、逐个小版本（截至 2026-09-20）

| 设备系统 | 远程配对 | 具体版本 |
|---|---|---|
| iOS / iPadOS 17.0 – 17.3.1 | ❌ | 17.0、17.0.1、17.0.2、17.0.3、17.1、17.1.1、17.1.2、17.2、17.2.1、17.3、17.3.1 |
| iOS / iPadOS 17.4 – 17.7.2 | ✅ | 17.4、17.4.1、17.5、17.5.1、17.6、17.6.1、17.7、17.7.1、17.7.2（17.x 收尾） |
| iOS / iPadOS 18.x | ✅ | 18.0、18.0.1、18.1、18.1.1、18.2、18.2.1、18.3、18.3.1、18.3.2、18.4、18.4.1、18.5、18.6、18.6.1、18.6.2、18.7 – 18.7.10 |
| iOS / iPadOS 26.x | ✅ | 26.0、26.0.1、26.1、26.2、26.2.1、26.3、26.3.1、26.4、26.4.1、26.4.2、26.5、26.5.1、26.5.2、26.6、26.6.1、26.6.2、26.7 |
| iOS / iPadOS 27.x | ✅ | 27.0（2026-09-14 发布） |
| iOS 16.x 及以下 | ❌ | 无 CoreDevice / RSD 链路（**而且 Seal 装不上**，见第五节） |

## 四、其他平台与主机

| 对象 | 状态 |
|---|---|
| **tvOS**（Apple TV） | 上游 **master 2026-08 才新增**（PR #79），需手动进「遥控器与设备 → 远程 App 与设备」配对模式；**上游未标注最低版本** ⇒ 未确认 |
| **visionOS** | 上游只写 *"visionOS devices"*，**没给版本号** ⇒ 未确认 |
| **watchOS** | 上游没有这条链路（配对文件 / RPPairing 均未提及）⇒ 不支持 |
| **电脑（主机）** | 上游出 macOS / Windows / Linux 三平台；**Seal 只构建 `windows-x64`**（`.github/workflows/pairing-assistant.yml` 的 `windows-2025` job） |
| **设备主动发起配对**（`_remotepairing-pairable-host._tcp`） | 上游 master README：需 **iOS 27 或更高**；**不在 Seal 固定的 0.1.14 里** |

## 五、对 Seal 意味着什么

1. **Seal 自己的部署目标是 iOS 17.0**（`project.yml` 四个 target 全是 `17.0`）
   ⇒ **iOS 16.x 及以下无法安装 Seal**，与配对方式无关。
2. **iOS 17.0–17.3.1**：Seal 能跑，但**只能走 Lockdown（本机配对）**。minimuxer 里这条链路是完整的
   （`Muxer.start` 按 `UDID` / `private_key` 分流；`LockDownInstall` 的 AFC 暂存 + instproxy 安装；
   `post17::mount_personalized_ddi` 走 lockdown 的 usbmuxd）。
   **配对助手自 run#185 起会按设备版本自动选**（`seal_mode_for_ios`）。
   ⚠️ 这条链路**在 Seal 里从未跑过真机** ⇒ 见 `device-regression-checklist.md` 第 15 项。
3. **iOS 17.4 及以上**：远程配对，助手按原样生成 RPPairing 文件。

## 六、怎么复核（结论过期时照这个来）

1. 上游 README（**先看 Seal 固定的那个 commit**，再看 master）：
   `https://github.com/jkcoxson/idevice_pair` —— 搜 `RPPairing for iOS`。
2. pymobiledevice3 的《iOS 17+ tunnels》指南 —— 搜 `CoreDeviceProxy`。
3. 版本清单：Wikipedia 的 `iOS 17` / `iOS 18` / `iOS 26` / `iOS 27` 各词条的 Version history 表。
4. 想确认「设备端到底有没有这个服务」，比读文档更硬的办法是**真机连一次**：
   `idevice_pair` 生成远程配对文件成功 ⇒ 该版本有 `CoreDeviceProxy` ✓。

## 七、完整性审计：Seal 里还有别的地方要求 17.4 吗？

**动机**：只把配对助手修好还不够 —— 如果 Seal 别处也硬性假设 17.4，那 17.0–17.3.1 拿到
Lockdown 文件照样会卡住。所以做了一次全仓审计（2026-09-20）。

**审计方法**：全仓 `grep` 这几个模式 —— `17.4` / `17_4` / `17.3` / `CoreDeviceProxy` /
`isRemotePairing` / `remotePairing` / `RPPairing`，覆盖 `Seal/**`、`Vendor/Minimuxer/Sources/**`、
`Vendor/Minimuxer/RustBridge/src/**`。

**结论**：

| # | 查了什么 | 结果 |
|---|---|---|
| 1 | `Seal/**` 与 `Minimuxer/**` 里有没有 `17.4` 闸门 | **一处都没有** ✓ —— 全仓唯一的 17.4 判据就在配对助手（本轮已修） |
| 2 | 版本分支的判据是什么 | 一律是 **`major < 17`**（pre17 / post17），**与 17.4 无关** ✓<br>`Mounter.swift:119`（DDI 挂载）、`Jit.swift:68`（调试）都是这个判据 |
| 3 | 装 App 走哪条路 | `Install.swift:26` 按 **配对文件类型**分流：`Muxer.isrppairing ? RPInstall : LockDownInstall` ✓<br>⇒ Lockdown 文件自动选 `LockDownInstall`；其注释写明**沿用 SideStore minimuxer 真机验证过的布局** ✓ |
| 4 | 个性化 DDI 挂载要不要 `CoreDeviceProxy` | **不要** ✓ —— `mount_personalized_ddi`（`post17.rs:193`）走 `TcpProvider`（usbmuxd TCP socket）+ `LockdownClient` + `ImageMounter` |
| 5 | 全仓哪里用了 `CoreDeviceProxy` | **只有一处**：`post17.rs:100` 的 `debug_app_post17`（**JIT / 调试启动**） |

**第 5 条的推论（已知缺口，但对 Seal 用户无影响）**：
`Jit.swift` 的分支是 `major < 17 ⇒ debugPre17`、否则 ⇒ `rustBridgeDebugAppPost17`（需要 `CoreDeviceProxy`）
⇒ **iOS 17.0–17.3.1 上「启用 JIT / 调试启动」无路可走**，会以 `CreateCoreDevice` 失败。
⚠️ **但 Seal 根本没有暴露 JIT 功能** —— 全仓只有 `CertificateExportHandler.swift:47` 一处注释
提到 LiveContainer 的「免 JIT 模式」✓ ⇒ 该缺口与 Seal 的「装 App / 续签」无关 ✓，本轮不改代码。

**因此**：iOS 17.0–17.3.1 的**安装与续签不依赖 17.4 的任何能力** ✓；
剩下的风险只在**运行时**（这条通道在 Seal 里从未跑过真机）⇒ 见
`device-regression-checklist.md` 第 15 项。

