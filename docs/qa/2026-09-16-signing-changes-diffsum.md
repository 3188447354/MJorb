# Seal 签名改动 · 工作区 Diff 摘要（2026-09-16）

> 供 macOS 上 Review。相对 HEAD 的工作区内容改动（`ApplePortalSigningService.swift` 的 M 仅是
> CRLF 行尾噪音，无内容 hunk，其单槽位运行时已在 HEAD 基线）。
> 静态守卫：`verify-release-safety.py` 128 源回归 + 54 守卫变更全 PASS。

---

## 1. C1 · 签名身份放宽 — `Seal/Infrastructure/Renewal/AppBundleSigningIdentityReader.swift`

**改前**：`inspectWithRorkSign` 要求所有可执行文件 `cmsSignatureValid && codeDirectoryHashesValid`，
任一哈希失败即抛 `inconsistentArchitectures` → 第三方签名 Seal 读不出身份 → 轮换被 `SEAL-CERT-232` 中断。

**改后**：识别身份只依赖「跨架构能读出一致的 CMS signer serial」；CMS/代码目录哈希状态降级为
`ExecutableSignerEvidence` 的诊断字段，不再作为识别失败依据。

```swift
let certificateReports = reports.compactMap { $0.signingCertificate }
guard let first = certificateReports.first else { throw IdentityReadFailure.signerMissing }
let normalized = …normalizedSerialNumber(first.serialNumberHex)
guard normalized.isEmpty == false,
      certificateReports.allSatisfy({ …normalized == normalized2($0.serialNumberHex) }) else {
    throw IdentityReadFailure.inconsistentArchitectures   // 仅保留跨架构串号不一致才判失败
}
let cmsValid = signedReports.allSatisfy(\.cmsSignatureValid)
let codeDirectoryValid = signedReports.allSatisfy(\.codeDirectoryHashesValid)
return ExecutableSignerEvidence(serialNumber:, cmsValid:, codeDirectoryValid:)
```

**兜底不变**：`readTarget` 仍要求 signer serial 在 `embedded.mobileprovision` 的开发者证书授权列表内
（`signerNotAuthorizedByProfile`），防误撤 Seal 自身证书的原始保护未删。

---

## 2. C2 · Bundle ID 团队后缀 — `Seal/Core/Signing/BundleIDMapper.swift`

**改前**：`requested` 非空时直接原样返回（可能是不带 team 后缀的裸 ID）。

**改后**：无论 `requested` 从哪来（UI 推荐 / 旧 preferred / 用户输入），最终签名 ID 强制带当前团队后缀：

```swift
if let requested, !requested.isEmpty {
    let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasSuffix(".seal.\(teamID.lowercased())") { return trimmed } // 已是本队后缀→复用
    return BundleIDPolicy.recommendedBundleIdentifier(for: trimmed, teamID: teamID)      // 否则换算(.seal.teamID)
}
return BundleIDPolicy.recommendedBundleIdentifier(for: original, teamID: teamID)
```

**动机**：裸 ID 会被不同 Apple ID（不同 team）的多设备注册，A 注册后 B 设备无法再注册使用（跨设备占用根因）。

---

## 3. C3 · 单槽位规格 — `Seal/Core/Signing/CertificateTakeoverPolicy.swift`

**改前**：`maximumCertificates` 默认 `2`（错误的两槽位假设）。

**改后**：默认 `1` + 注释明确单槽位语义（空槽位建 / 满槽位撤「非 A」/ 未知 signer 阻断）。

> 注：本策略是验收规格（`verify-release-safety.py` 与 `CertificateTakeoverPolicyTests` 断言）；
> 运行时同义逻辑由 `ApplePortalSigningService` 慢速路径的 `SigningCertificateMaterialPolicy.rotationCandidates`
> 驱动（已在 HEAD 基线，撤「非 A」→ 建 → 成功即停 + `sealSignerConfirmed` 守门）。文件头加了交叉引用，
> 约束两侧同步，防漂移。

---

## 4. D · 文档/注释收口

- `SelfManagedSealMigrationPolicy.swift`：注释标注 `.t<teamID>`/`.self` 为早期迁移旧格式，与正式
  `.seal.<teamID>` 不混用（仅注释，不改逻辑）。
- `docs/superpowers/specs/2026-09-15-account-certificate-management-design.md`：证书模型改单槽位。
- `docs/qa/2026-09-15-self-renewal-device-matrix.md`：B1 判据由「占满两个证书槽位」改为单槽位表述。
- `docs/qa/2026-09-16-signing-model-verification.md`：**新增**，编译+真机验收清单。

---

## 5. 未改（按你的决定）

- **问题2（自续签身份源改 Keychain）**：已回退，保留 `installedIdentity`（Mach-O CMS 解析）。
- **Bundle ID 长度护栏 / `.t<TeamID>` 旧格式识别**：暂缓，仅记录。
- **证书页手动建证书不自动先撤后建**：按设计保持只读，由签名链路接管。

## 待办

编译 + 真机回归（微信 / 黄豆短剧 / LCSign / lanmanga），按 `2026-09-16-signing-model-verification.md` 执行回填。