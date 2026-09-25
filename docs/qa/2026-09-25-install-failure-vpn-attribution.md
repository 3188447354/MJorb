# 安装失败的归因：从「按错误码前缀一刀切」改成「按提示文案」

- 日期：2026-09-25
- 版本：1.3.16
- 触发：用户要求「只要开了外部 LocalDevVPN，就一定不要以为 VPN 来影响所有体验」
- 守卫：**R83**（12 条断言 + 11 个变异锚点；守卫 638/383 → 650/394）

## 一、现象

任何 `SEAL-INSTALL-*`（安装族）失败，弹窗上唯一的「恢复」按钮都会把用户送进
**「设置 → LocalDevVPN」**页面 —— 包括与本地隧道**毫无关系**的那些失败：

| 错误码 | 它在说什么 | 用户真正该做什么 |
|---|---|---|
| `SEAL-INSTALL-702s` | 设备存储空间不足 | 清理设备存储 |
| `SEAL-INSTALL-702l` | 免费账号 3 应用上限 | 卸载一个自签应用 |
| `SEAL-INSTALL-702f` | 砸壳包的 DRM 元数据残留 | 重新砸壳 |
| `SEAL-INSTALL-702t` | 安装超时（**超时 ≠ 失败**） | 等一会儿回列表看是否已装上 |
| `SEAL-INSTALL-711…730` / `735` | 签名包内容类（缺失/损坏/过期/Team 不符） | 重新签名 |
| `SEAL-INSTALL-737` / `738` | 自更新事务未就绪 / 上一笔安装仍在跑 | 重启 Seal |
| `SEAL-INSTALL-716` | 本机签名包记录不完整 | 重新签名 |

用户点完被送到一个**解决不了他问题**的页面，只能自己再退回来 —— 这就是
「把所有问题都算到 VPN 头上」。

## 二、根因（三处，同一族）

### 1. 跳转判据判的是「码的形态」

`AppsViewModel.settingsRoute(for:)`：

```swift
if failure.code.hasPrefix("SEAL-INSTALL-") { return .localDevVPN }
```

安装族一共 47 个码（源码扫描），这一条把**全部**它们路由到 VPN 页。

### 2. 配对类失败被给出「重新安装」按钮

`SEAL-INSTALL-703`（设备配对不可用）与 `707`（无法刷新已安装应用）带 `SEAL-INSTALL-` 前缀
⇒ 落进 `InstallFailureActionPolicy.action(for:)` 的**前缀兜底** ⇒ 界面给出「重新安装」。
而它们的 recovery 文案是「重新连接手机并完成配对后重试」——
**重装修不好一份失效的配对文件**。

同一处还有第二个缺口：`SigningProgressView.isPairingFailure` 只认 `SEAL-PAIR-` 前缀
⇒ 认不出 703 / 707 ⇒ 按钮永远换不成「重新配对设备」。

### 3. 过时文案（与代码注释直接矛盾）

`SEAL-INSTALL-701` 的 reason 仍在写「**付费账号的 Seal 会自动拉起内置隧道**」。
而内置 `SealTunnel` 早已移除（`SealTunnel/` 目录已空），
`LocalDevVPNOnDemandActivator` 与 `MinimuxerInstallChannel` 的注释都明说
「不再自动拉起内置隧道」。另外 5 处文案按「免费账号 / 付费账号」区分隧道依赖 ——
实际上**与账号类型无关**。

## 三、修复

1. **新增 `Seal/Features/Settings/InstallFailureSettingsRoute.swift`**：
   判据变成**显式码集合**（8 条：`701` / `705` / `706` / `706a` / `706b` / `706t` / `708` / `710`），
   其余一律返回 `nil`（**不跳转**，由弹窗文案自己说明下一步）。
   配对族**不重复定义**，引用 `InstallFailureActionPolicy.pairingCodes`（单一真源）。
   集合的判据是「**recovery 文案本身在引导用户去检查 LocalDevVPN**」：
   - 6 条：recovery 恰为 `检查是否打开 LocalDevVPN`（701 / 705 / 706b / 706t / 708 / 710）；
   - 1 条：706 —— 由 `presentVPNRecovery` 配套 `pendingVPNAction` 使用；
   - 1 条：706a —— 设置页自己的「LocalDevVPN 未就绪」。

2. **`InstallFailureActionPolicy` 新增 `pairingCodes = {703, 707}`**，
   并把配对判定排在**前缀兜底之前**（顺序就是安全本身：排到后面时这两条会被算成
   「重新安装」，而代码看起来仍然有配对判据）。

3. **`SigningProgressView.isPairingFailure`** 把这两条一并认成配对失败。

4. **6 处用户可见文案**：
   - 701：「Seal 不内置隧道（内置隧道已移除），一律依赖外部 LocalDevVPN 软件把流量真正转发到设备」；
   - 另外 5 处：「（Seal 依赖外部 LocalDevVPN 软件提供本地隧道）」。

## 四、守卫与测试

- **守卫 R83**（12 条断言 + 11 个变异锚点）：

  | 编号 | 判据 |
  |---|---|
  | R83① | `settingsRoute` 必须委派给 `InstallFailureSettingsRoute`，且不得再出现「前缀 ⇒ `.localDevVPN`」 |
  | R83② | 通道码集合必须**逐个点名**列出 8 个码 |
  | R83③ | 通道码集合必须**恰好 8 条**（新增/删除要同步） |
  | R83③b | **同源闸门**：recovery 恰为「检查是否打开 LocalDevVPN」的每一条失败，其 code 必须在集合里；且这样的失败 ≥ 5 条（防正则漂移后变成空集 ⇒ 永远绿） |
  | R83④ | 通道码集合不得含配对码 703 / 707 |
  | R83⑤ | `pairingCodes` 必须显式列出 703 与 707 |
  | R83⑥ | `action(for:)` 里配对判定必须排在**前缀兜底之前**（用下标比顺序） |
  | R83⑦ | `isPairingFailure` 必须认这两条 |
  | R83⑧ / ⑨ | 过时文案不得复活（「付费账号会自动拉起内置隧道」/「免费账号需…」） |
  | R83⑩ / ⑪ | 两个测试文件里的关键单测必须存在 |

- **单测**：
  - `SealTests/Settings/InstallFailureSettingsRouteTests.swift`（新）：三方向 ——
    ① 8 个通道码 ⇒ `.localDevVPN`；② 18 个与 VPN 无关的安装码 ⇒ `nil`；
    ③ 703 / 707 ⇒ `.pairing`；外加 `SEAL-PAIR-*`、`SEAL-AUTH-*`、`SEAL-CERT-*` 保持原状，
    以及「通道码集合与三个动作集合两两不相交」。
  - `SealTests/Installation/InstallChannelDiagnosticClassificationTests.swift`：
    新增 `pairingPrefixedInstallCodesAreNotReinstall()`；
    `actionSetsAreDisjoint()` 扩为**三**集合两两互斥。

## 五、真机验证（⚠️ 待验）

| # | 操作 | 期望 |
|---|---|---|
| 1 | 让一个**与隧道无关**的失败发生（装一个超过设备剩余空间的包；或免费账号装第 4 个应用） | 弹窗点「恢复」/「知道了」后**不应**跳到 LocalDevVPN 页 |
| 2 | 关掉 LocalDevVPN，再点「续签」 | 应出现通道类失败，且弹窗**能**跳到 LocalDevVPN 页（这条是**阳性对照**：不能因为修了 1 就把真正该跳的也修没了） |
| 3 | 设置 → 设备配对 → 导入一份无效配对文件，再点续签 | 若出现 `SEAL-INSTALL-703` / `707`，按钮应是「**重新配对设备**」而不是「重新安装」 |
| 4 | 设置 → 设备配对 里看 701 的文案 | 不应再出现「付费账号的 Seal 会自动拉起内置隧道」 |

判据：①③④ 靠**肉眼**即可；②需要先确认弹窗按钮跳转到了 LocalDevVPN 页
（该页的按钮是「检测当前 VPN…」）。
