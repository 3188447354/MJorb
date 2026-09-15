# DEBUG_LOG

> 复盘记录：现象 → 根因 → 修复 → 涉及文件 → 验证状态。新条目追加到「历史记录」顶部（最新在前）。
> 动手前先查阅下方「常犯坑位」，避免同类问题重复发生。

---

## 常犯坑位

- **证书序列号跨来源比对必须归一化**（strip leading zeros），否则会用不同表示误判「证书被轮换/不在授权列表」。
- **进度条卡 % 是阶段切换时机问题，不是进度值本身**。排查进度显示别盯着百分比，要看阶段切换回调。
- **`rg` 查询带再加工时，行号输出用 `-n`，别拿 `-r` 当行号**。
- **证书轮换 / 证书自动清理两条撤销路径都要各自守住「无法确认 Seal 真实签名证书就禁止撤销」**，缺一条就会误删 Seal 自己的命根子证书。
- **iLoader 等第三方签名工具产出非标准签名结构/描述文件**，Seal 的 `AppBundleSigningIdentityReader` 读不出真实 CMS 签名者，会连锁触发 SEAL-CERT-232 / SEAL-SELF-105，只能电脑覆盖安装兜底，改代码弱化身份校验是明令禁止的。

---

## 历史记录

### 2026-09-16 · iloader 非标准签名导致 Seal 无法自续签

- **现象**：设备上续签 Seal 时，证书页读不出完整证书；点续签后弹出「无法确认当前 Seal 的签名证书」，恢复文案「先用电脑的原签名工具覆盖安装一次 Seal，再回来续签」。日志另出现 SEAL-SELF-105「无法确认当前 Seal 的签名身份」。
- **根因**：当前正在运行的 Seal 由 iloader 用非标准签名结构签名，主程序/网络扩展的真实 CMS 签名者无法被 `AppBundleSigningIdentityReader` 读出。身份读不完整 → 既不敢撤销（SEAL-CERT-232）、也不敢覆盖装自己（SEAL-SELF-105）。这是设备现实状态，不是代码 bug，且不能靠弱化身份校验绕过。
- **修复/处置**：电脑覆盖安装（不卸载），保持同一 Apple ID（sunuannian1@gmail.com）、Team（CT8QZ7352B）、主/扩展 Bundle ID 一致，改用能产出标准签名的签名工具。
- **涉及文件**：`Seal/Infrastructure/Renewal/AppBundleSigningIdentityReader.swift`、`Seal/Core/Renewal/SelfReplacementCoordinator.swift`。
- **验证状态**：待用户电脑覆盖安装后，回读新日志确认身份读取完整。

### 2026-09-16 · 证书轮换在无法确认 Seal 真实签名证书时仍撤销

- **现象**：续签 Seal 时，即使读不出运行中 Seal 的 signer，日志仍出现「证书轮换：撤销 …序列号，原因=无本机私钥，运行中Seal=否」，把唯一一张无本机私钥的证书当普通孤儿撤了，随后创建新证书签名，但安装被 SEAL-SELF-105 拦住。
- **根因**：`rotateCertificatesAndCreateIdentity` 未区分「签名/续签 Seal 本身」与「签名普通 App」。读不出 signer 时把 `sealActualSignerSerials` 置空，导致运行中 Seal 证书被误标为「运行中Seal=否」进入可撤销集合。
- **修复**：新增 `sealSignerConfirmed` 标志；`isSeal == true` 且读不出运行身份时，前置抛出 `SEAL-CERT-232`（无法确认当前 Seal 的签名证书），在撤销发生前就止步。普通 App 不涉及 Seal 身份，不受影响。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`。
- **验证状态**：`Scripts/verify-release-safety.py`（128 源码回归 + 54 变异）全过，CI build-package / rork-sign-tests / swift-regression 全绿；真机日志确认旧版误撤、新版已止步于 SEAL-CERT-232。

### 2026-09-16 · SelfReplacementFailure 被兜成笼统 SEAL-SIGN-500

- **现象**：自更新安装分支抛出的 `SelfReplacementFailure` 未被映射为 `ImportFailure`，被 `AppsViewModel.unexpectedSigningFailure` 兜成笼统「SEAL-SIGN-500」，用户拿不到可操作指引。
- **根因**：`SelfReplacementFailure` 四种 case（runningIdentityUnknown / bundleShapeChanged / localSigningIdentityUnavailable / candidateChanged）未做错误码映射。
- **修复**：在 `SigningCoordinator` 新增 `selfReplacementFailure(_:)`，映射为 SEAL-SELF-105～108，兜底 SEAL-SELF-109，标题统一「Seal 自更新中止」；自更新安装分支 try/catch 捕获并转 `ImportFailure`。
- **涉及文件**：`Seal/Core/Signing/SigningCoordinator.swift`。
- **验证状态**：提交 `edc7971`，CI build-package / rork-sign-tests / swift-regression 全绿，回归测试未破坏。