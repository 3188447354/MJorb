# 证书轮换闸门把免费账号锁死（构建 47 真机）

- 日期：2026-09-26
- 输入日志：`Seal-log(26)(1).txt`，构建 **1.3.17 / 47**（09:03–09:05）
- 用户原话：「你这不自动给我撤销证书，我下载 seal 啥也干不了，全被拦截了」

## 现象（日志时间线）

```
09:04:32  准备签名：LiveContainer
09:04:39  证书轮换：候选只剩 Seal 正在使用的证书 ⇒ 不自动撤销（撤销后 Seal 需重装…）
09:04:41  [SEAL-CERT-204b] 签名证书数量已达上限 …code=3022
09:05:06  准备签名：微信
09:05:19  证书轮换：候选只剩 Seal 正在使用的证书 ⇒ 不自动撤销
09:05:22  [SEAL-CERT-204b] …code=3022
09:05:36  开始续签：Seal …ID：com.mjorb.seal.CT8QZ7352B
09:05:39  [SEAL-PROFILE-334] 当前证书不可续签：profile-only 只能复用…本机证书
```

⇒ **签第三方 App、签第二个 App、续签 Seal 自己，三条路径全部失败**。

## 根因

1.3.17（`e3d216f`）为修「撤销运行中 Seal 的证书 → 自替换安装失败 → Seal 变砖」
（构建 38 / 46 的 `SEAL-SELF-109`），在 `ApplePortalSigningService` 的
**撞 204b 后的轮换分支**前加了一道闸门：

```swift
let rotationCandidates = SigningCertificateRotationGate
    .candidatesExcludingRunningSealCertificate(candidates: candidates, isSigningSeal: isSeal)
guard rotationCandidates.isEmpty == false else { … throw failure }
```

`isSigningSeal == false` 时**剔除所有「运行中 Seal 正在用」的候选**；剔除后为空 ⇒ 抛回 204b。

**死锁条件**（三条同时成立即永久锁死）：

1. 免费团队只有 **1 个**活动证书槽位（Apple 硬限制）；
2. Seal 自己的证书在**覆盖安装后必然丢失本机私钥**（外部工具签发 ⇒ 本机没有 P12）；
3. ⇒ 该证书**就是唯一候选** ⇒ 被闸门剔除 ⇒ 永远建不出新证书 ⇒ 204b。

**「剔除」本来就是多余的**：`SigningCertificateMaterialPolicy.rotationRank` 早已把
Seal 的证书排在**最后**（`isRunningSealCertificate ⇒ 3`；普通证书
`invalidValidity ⇒ 0` / `insufficientLifetime ⇒ 1` / `missingPrivateKey ⇒ 2`）
⇒ 只有「别无选择」时才会撤到它。原设计就是「最后撤 Seal 的证书 → 本事务末尾自替换恢复」。

**其余两条路径也都跳过 Seal 的证书** ⇒ 没有任何出口：

| 路径 | 行为 |
| --- | --- |
| `SigningCoordinator.revokeKeylessCertificatesAfterConfirmation`（`SEAL-CERT-204e`） | `sealProtectedSerials` 命中即 `continue` 跳过 |
| `CertificateCleanupPolicy.makePlan` 自动清理 | `serial == normalizedSealSigner` ⇒ `kept` ⇒ `revocable` 为空 ⇒ `.noCandidates` |

## 修复

1. **删除** `Seal/Core/Signing/SigningCertificateRotationGate.swift`（整个文件）。
2. **改** `Seal/Infrastructure/Signing/ApplePortalSigningService.swift`：
   去掉闸门调用与 `guard … throw failure`，恢复 `candidates: candidates,`；
   注释改为说明「为什么**必须**允许撤到 Seal 那一张」与三条安全网。
3. **规格侧同步**：`Seal/Core/Signing/CertificateTakeoverPolicy.swift` 的 `decide` 由
   「满槽位只撤非 A」改为「**普通证书在前、A 排最后但仍进候选**」；
   单测 `fullSlotsRequestRevocationOfNonSignerCertificatesOnly` /
   `signerWithLeadingZeroIsNeverARevocationCandidate` / `fullSlotsWithOnlySignerBlocks`
   分别改为 `fullSlotsPreferNonSignerCertificatesAndKeepTheSignerLast` /
   `signerWithLeadingZeroIsStillOrderedLast` / `fullSlotsWithOnlySignerStillOffersIt`。
   ⚠️ 那条 `fullSlotsWithOnlySignerBlocks` 断言「只剩 A 一张时必须 blocked」——
   **它把死锁钉成了契约**，是「别为豁免写单测」的又一实例。

### 安全性由三条保证（缺一条都不行）

| # | 机制 | 位置 |
| --- | --- | --- |
| ① | Seal 的证书**排到最后**（只有别无选择才轮到它） | `SigningCertificateMaterialPolicy.rotationRank` |
| ② | 撤销前**必须**发 warning 说清后果（Seal 将在本事务末尾重装） | `rotateCertificatesAndCreateIdentity` |
| ③ | 撤销后由**证书轮换恢复子流程**以新证书重签并重装 Seal | `resignAppsAffectedByCertificateRotation(includeSeal: true)` |

⇒ **变砖的真凶是自替换安装失败**（构建 38 / 46 的 `SEAL-SELF-109`），不是撤销本身。
「不撤」的代价是链路整体不可用 ⇒ 修错了环节。

## 上游对照（SideStore）

`CertificateProvisioningFlow`：**先创建** → 撞 3022 → 才 `replaceCertificate`（撤销 → 再创建）。
它**从不把自己排除在候选之外**（Seal 没有内嵌证书，也就没有上游 `CacheSigningCertOperation`
那套自身跳过）⇒ 本次恢复的行为与上游一致。

## 守卫与测试

- 守卫 **R84⑥** 改为**反向契约**：
  - `"SigningCertificateRotationGate" not in`（闸门不得复活，先 `strip_comments`）；
  - `"candidatesExcludingRunningSealCertificate" not in`；
  - `"guard rotationCandidates.isEmpty == false else {" not in`；
  - `"candidates: candidates," in`（候选必须原样传给轮换）；
  - `"if candidate.isRunningSealCertificate { return 3 }" in`（Seal 必须排最后）。
- 变异锚点：**⑥** 候选换成 `rotationCandidates,`；**⑥b** `rotationRank` 的 `return 3 → -1`；
  **⑥c** 把闸门调用插回调用点 ⇒ 三条都必须让 R84⑥ 报红。
- **R84⑧** 的单测名单换成
  `capacityRecoveryStillOffersTheRunningSealCertificateWhenItIsTheOnlyOne`。
- Takeover 断言改为 `let ordered = ordinaryCandidates + runningSealCandidates`
  （⚠️ 第一版只断言两个变量**存在**＋返回值用了 `ordered` ⇒ 变异把
  `ordinaryCandidates + runningSealCandidates` 改成 `ordinaryCandidates` 时**抓不住** ——
  `check-mutation-power.py` 当场报 `BAD = 1`，这就是它存在的意义）。
- 新增单测：
  - `SigningCertificateMaterialPolicyTests.capacityRecoveryStillOffersTheRunningSealCertificateWhenItIsTheOnlyOne`；
  - `CertificateTakeoverPolicyTests.fullSlotsWithOnlySignerStillOffersIt`。

## 待真机验证（构建 48）

1. 免费账号 + Seal 自己的证书无本机私钥（覆盖安装后必然如此）⇒ 点「签名并安装」一个第三方 App：
   **应成功**；日志里应看到
   `证书轮换：撤销 …，原因=无本机私钥，运行中Seal=是` ＋
   `证书轮换：本轮将撤销 1 张 Seal 正在使用的证书（…）；Seal 将在本事务末尾以新证书重新安装`。
2. 撤销后**必须**在日志里看到 Seal 被重签并重装（`开始自替换安装` → 回主屏）。
   ⚠️ 若这一步失败（`SEAL-SELF-109`），Seal 会打不开 —— 这是**已知的、需要单独修**的风险，
   与本次「恢复轮换」是两件事。
3. 续签 Seal 自己：**不应**再出现 `SEAL-CERT-204b`（3022）。
