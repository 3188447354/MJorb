# Seal 签名模型三改动 · 编译与真机验收清单（2026-09-16）

> 对象：本次会话三处改动（问题1 签名身份识别放宽 / 问题3 单槽位证书模型 / Bundle ID 团队后缀保持现状）+
> 文档与注释收口。Windows 侧只能跑静态守卫（`verify-release-safety.py`），编译与真机闭环必须在
> macOS + Xcode + 真机执行。所有用例结果按本表回填。

**脱敏规则（强制）**：不得记录 Apple ID、密码、完整证书序列号、完整设备 UDID 或 P12。
证书只记角色（A = 电脑/外部签名证书 / B = 本机创建证书 / C = 其他候选）与序列号末 4 位；
事务只记 Transaction ID 后缀（末 8 位）。

**回归样本（强制）**：微信 / 黄豆短剧 / LCSign / lanmanga。签名安装三链路（签名/续签/自续签)
任一改动都必须走至少一个回归样本覆盖。

---

## 0. 本批改动范围

| 编号 | 改动 | 涉及文件 | 验收重点 |
|---|---|---|---|
| C1 | 签名身份读取放宽（不再因 `codeDirectoryHashesValid` 失败而判 `inconsistentArchitectures`，仅依赖能读出的一致 CMS signer serial；CMS/哈希状态降级为诊断字段） | `AppBundleSigningIdentityReader.swift` | 第三方签名的 Seal 能被识别身份，不再误触 `SEAL-CERT-232` |
| C3 | 免费团队证书模型：单槽位接管（不是两槽位），撤销「非 A」即创建、每张立即尝试、成功即停、signer 未知一律阻断 | 设计文档 + `CertificateTakeoverPolicy.swift`（规格）+ `SigningCertificateMaterialPolicy.rotationCandidates`（运行时） | 空槽位建 B / 满槽位撤销 C 建 B / 未知 signer 阻断 / 无可释放槽位阻断 |
| C2 | Bundle ID 团队后缀 `.seal.<TeamID>`（上轮已改，本轮**用户确认保持现状不改**） | `BundleIDMapper.swift` / `BundleIDPolicy.swift` | 仅回归确认普通 App 签名→安装→续签链路无回归 |
| D | 文档/注释收口（QA 设备矩阵改单槽位表述、接管策略与运行时交叉引用、旧迁移格式注释） | `docs/qa/*.md` / 两个策略注释 | 文档不再含两槽位错误表述 |

> 种子判断：C1 的放宽只影响「识别 signer serial 的目的」，原「防误撤自身证书」保护仍由
> `readTarget` 的 profile 授权校验兜底；若真机出现 Seal 打不开/证书被误撤，优先回归 C1。

---

## 1. 静态守卫（Windows 可跑，已绿）

- [x] `python Scripts/verify-release-safety.py` → 128 项源回归 + 54 项守卫变更全 PASS。
- [ ] Xcode 编译通过，无警告级红线（`xcodegen generate` 后 build）。
- [ ] `bash Scripts/ci-test.sh` 全绿（含 `CertificateTakeoverPolicyTests`、`SignedIPAIdentityReaderTests`、`SelfReplacementCoordinatorTests`）。
- [ ] `swift test --package-path Vendor/rork-sign` 全绿。

---

## 2. 编译 / 构建前置（macOS）

1. [ ] `xcodegen generate`
2. [ ] `bash Scripts/ci-test.sh`
3. [ ] `swift test --package-path Vendor/rork-sign`
4. [ ] 未签名 IPA 校验：`SEAL_IPA_CONFIGURATION=Release SEAL_SKIP_XCODEGEN=1 bash Scripts/build-unsigned-ipa.sh` + `bash Scripts/verify-ipa.sh build/Seal_*.ipa`

---

## 3. 真机回归样本（C1/C2/C3 共用底线）

对每个样本（微信 / 黄豆短剧 / LCSign / lanmanga）执行：

- [ ] 全新建记录 → 选中账号 → 签名成功入库。
- [ ] 覆盖安装成功，App 可正常打开（重点验证 `mappedBundleIdentifier` 与描述文件一致）。
- [ ] 签出的 Bundle ID 带 `.seal.<TeamID>` 后缀（除 Seal 自身 canonical）。
- [ ] 续签路径复用它自己的 `mappedBundleIdentifier`，ID 不变。
- [ ] 到期日前能正常续签，不报设备槽位/证书占用误拦。
- [ ] 安装日志脱敏合规（无 Apple ID 明文 / 完整序列号）。

### C1 专项（第三方签名 Seal 识别）

1. [ ] 用 Sideloadly / 爱思助手把 Seal 签名安装到真机（覆盖本机现有 Seal）。
2. [ ] 启动后进入证书页 / 自续签流程，**应能读到当前 Seal 真实 signer**（序列号末 4 位记录于 Notes）。
3. [ ] 不应再报 `inconsistentArchitectures` / `SEAL-CERT-232`。
4. [ ] 走完一次自续签接管：能识别身份 → 撤销「非 A」→ 创建 B → 安装 → 新 Seal 确认真实签名者为 B。
5. [ ] 新 Seal 启动后数据容器仍在（已签 App、账号无丢失）。

### C3 专项（单槽位接管）

| Case | 场景 | 通过判据 |
|---|---|---|
| T1 | 空槽位 + 可确认 A | 直接创建 B，不动 A；A 仍可见 |
| T2 | 已有 A + C（历史残留） | 页面标 A 为「当前签名者」并禁撤 A；撤销 C → 创建 B → 安装 → 确认真实签名者为 B |
| T2b | T2 后若 B 创建失败 | A 仍可正常启动 Seal（不可撤销 A） |
| T3 | signer 未知（`installedIdentity` 读不出） | 自动轮换路径阻断，报 `SEAL-CERT-232`，绝不盲撤任何证书 |
| T4 | 只剩 A 一张且满槽位 | 没有可安全释放的槽位 → 阻断，等电脑处理 |
| T5 | 不落两槽位 | 全程不生成本机第二张并行证书；创建 B 不触发 3022/7460 |

### C2 专项（Bundle ID 现状回归，不新增行为）

1. [ ] 同一 Team 下重复签名同一 App 得到相同 Bundle ID（确定性）。
2. [ ] 换不同账号（不同 Team）签名，Bundle ID 带不同 `.seal.<TeamID>` 后缀，互不占用。
3. [ ] 普通 App 换账号并未migrate，签入后容器/Keychain 数据随 Team 变化这一硬约束由 UI 提前提示（不回归即可）。

---

## 4. 结论栏

- 编译：通过 / 失败（附日志）
- 静态守卫：通过 / 失败
- 真机回归（每个样本）：通过 / 失败（附用例与序列号末 4 位）
- 遗留事项与是否需回退

---

## 5. 备注 / 坑位

- 证书序列号跨来源比对必须归一化（去前导 0），这是常犯坑位。
- C1 放宽只作用于「识别 signer」；`readTarget` 的 profile 授权校验仍在，不要删。
- 若真机出现误撤自身证书，回归检查 `sealSignerConfirmed` 判定与 `rotationCandidates` 排序。