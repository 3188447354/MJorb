# Seal 自续签身份 · 真机闭环验收记录（2026-09-15）

> 本表用于阶段一 Task 13 真机闭环验收。Windows 侧无法执行真机用例，
> 所有用例结果均「待真机验证」，由 macOS + 真机环境执行后回填。

**脱敏规则（强制）**：不得记录 Apple ID、密码、完整证书序列号、完整设备 UDID 或 P12。
证书只记角色（A = 电脑签名证书 / B = 本机创建证书 / C = 其他候选）与序列号末 4 位；
事务只记 Transaction ID 后缀（末 8 位）。

## 验收记录表

| Case | Device | iOS | Initial signer | Slots | Interruption | Result | Transaction ID suffix | Notes |
|---|---|---|---|---|---|---|---|---|
| A1 | iPhone | 17.x | Computer A | A + empty | none | 待真机验证 |  |  |
| A2 | iPad | supported latest | Computer A | A + empty | none | 待真机验证 |  |  |
| B1 | iPhone | supported latest | Computer A | A + C | none | 待真机验证 |  |  |
| C1 | iPhone | supported latest | Local B | B + empty | kill during install | 待真机验证 |  |  |
| C2 | iPhone | supported latest | Local B | B + empty | tunnel loss | 待真机验证 |  |  |
| D1 | iPhone | supported latest | Local B | B + empty | second renewal | 待真机验证 |  |  |
| E1 | iPhone | supported latest | changed/unknown | varies | PC overwrite recovery | 待真机验证 |  |  |

## 各用例通过判据

### A1 / A2 · 空槽位接管（iPhone / iPad）

1. 电脑证书 A 签名安装 Seal → 启动正常。
2. Seal 内执行自续签 → 创建本机证书 B。
3. 安装提交日志中该 transactionID 只出现一次。
4. 新 Seal 启动后，证书页「当前真实签名者」显示 B（序列号末 4 位记录于 Notes）。
5. A 未被撤销（Apple Portal 证书列表仍可见 A）。
6. 数据容器仍在（已签应用、账号、记录无丢失）。

### B1 · 满槽位接管（单槽位）

> 免费团队只有一个「活动 iOS 开发证书」槽位（Apple 硬限制）。旧两槽位时代历史残留可能同时存在 A + C，
> 但新链路一律按单槽位处理：撤销「非 A」的 C 后立即创建 B，绝不并行创建第二张。

1. 远端已有 A + C（历史残留）→ 证书页明确标注 A 为「当前签名者」并禁止撤销 A；C 只在持有私钥可复用或确认为非 A 时释放。
2. 页面呈现 C 的本机关联与其他设备风险说明，需用户确认后才撤销 C。
3. 撤销 C → 创建 B → 安装 → 新 Seal 确认真实签名者为 B。
4. 若 B 创建失败，确认 A 仍可正常启动 Seal。

### C1 / C2 · 中断与未知状态

1. 分别在上传、安装 API 超时、旧进程终止（kill）、新进程首次启动前断开通道（tunnel loss）四种中断下执行。
2. 每个 transactionID 的安装提交次数必须为 1（查安装日志断言）。
3. 重启后只做对账：部分身份或扩展不一致时进入「需要电脑覆盖恢复」，绝不自动重装。

### D1 · 连续两轮续签

1. 接管完成后连续执行两轮续签。
2. 两轮证书始终为 B；只更新 profile UUID 与到期时间。
3. 第二轮不创建、不撤销任何开发证书（Apple Portal 证书数量不变）。

### E1 · 电脑覆盖恢复

1. 用相同 Bundle ID、扩展 Bundle ID 和 Team 从电脑覆盖安装，不卸载。
2. 启动后数据仍在。
3. 旧事务失去执行权（不再被结算/提交）。
4. 状态被重新识别为「电脑签名，等待本机接管」或与真实身份对应的状态，绝不误判为本机自管理。

## 执行前置条件

- macOS CI 全绿：`xcodegen generate`、`bash Scripts/ci-test.sh`、`swift test --package-path Vendor/rork-sign`。
- 未签名 IPA 校验通过：`SEAL_IPA_CONFIGURATION=Release SEAL_SKIP_XCODEGEN=1 bash Scripts/build-unsigned-ipa.sh` + `bash Scripts/verify-ipa.sh build/Seal_*.ipa`。
- 回归样本（微信 / 黄豆短剧 / LCSign / lanmanga）签名安装链路无回归。
