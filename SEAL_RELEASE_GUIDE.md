# SEAL_RELEASE_GUIDE.md — Seal 版本发布操作手册

> 面向后续会话/作者，按步骤可复现地把代码改动发布出去。
> 前置：本机是 Windows（**不能编译**），代码产物一律由 GitHub Actions 云编译。
> 关联：`AGENTS.md`（纪律）、`RELEASE_NOTES.md`（发布正文）、`project.yml`（版本号）。

## 0. 三句话速记

1. 改代码 + **bump 版本** + 写 `RELEASE_NOTES.md` → 提交推送。
2. 按改动大小选 workflow → 触发快速档或完整档。
3. 等编译绿 → 自动发到 `sunuannian1/Seal-Releases`（内置更新检测即触发提示）。

---

## 1. 发布前准备（每次必做）

- [ ] **bump `MARKETING_VERSION`**：`project.yml` 里 `MARKETING_VERSION: X.Y.Z`（Seal 主 target 与 SealTunnel
      扩展是同一处/同一值，用替换即可）。新旧版本对比驱动内置更新弹窗，忘记 bump = 用户检测不到新版本。
- [ ] **写 `RELEASE_NOTES.md`**：这就是发布正文，随 `gh release create` 直接上。可按场景写：
      - 面向内测：仅出构建产物，保持 `publish_release=false`；文案警告不能防止客户端检测到已发布版本。
- [ ] 提交并推送：`git add ... && git commit -m "..." && git push`。

> 不用手动改 `CURRENT_PROJECT_VERSION`：CI 用 `GITHUB_RUN_NUMBER` 覆盖，`project.yml` 里的只是本地兜底。

## 2. 选档：快速档 vs 完整档

| 场景 | 用哪个 |
|---|---|
| 只改 Swift 业务逻辑（UI、签名协调、安装错误分类、日志、续签等） | **`ios-release.yml`（iOS Release Fast）** |
| 改了 Rust / RustBridge / 签名器 / 安装链路 / 需要 UI 回归 | **`ios.yml`（iOS，完整归档）** |

两种都会：Release 编译 → 打包 unsigned IPA → 校验 → 发布到 `sunuannian1/Seal-Releases`。
区别：快速档跳过模拟器 UI 回归与 rork-sign 测试门，约 10 分钟；完整档约 60 分钟。

## 3. 触发发布

```bash
# 快速档（默认，日常 90% 用它）
gh workflow run ios-release.yml -f publish_release=true

# 完整档（大改动、需回归门）
gh workflow run ios.yml --ref main -f publish_release=true
```

触发后立刻拿 run 号：
```bash
gh run list --workflow ios-release.yml --limit 1
```

## 4. 后台等待并看结果

```powershell
$runId = <上一步查到的 run 号>
while ($true) {
  $j = gh run view $runId --json status,conclusion | ConvertFrom-Json
  if ($j.status -eq 'completed') {
    "FINAL: status=$($j.status) conclusion=$($j.conclusion)"
    if ($j.conclusion -ne 'success') { gh run view $runId --log-failed 2>&1 | Select-Object -Last 220 }
    break
  }
  Start-Sleep -Seconds 30
}
```

- `conclusion=success` → Release 已发布。
- 失败 → 看 `--log-failed` 尾部。常见两类：
  1. `curl (6) Could not resolve host: github.com` 或 XcodeGen SHA 失败：GitHub 基础设施瞬时故障，
     直接 `gh run rerun $runId --failed` 重跑。
  2. `openssl/err.h not found`：CI 缓存把 OpenSSL 二进制删了——检查并根治，**不要靠反复 rerun 碰运气**
     （缓存步骤见 `AGENTS.md` §7）。

## 5. 发布产物核对

发布目标：**`sunuannian1/Seal-Releases`**（内置更新从这里检测/下载）。

```bash
gh release view v<你的版本> --repo sunuannian1/Seal-Releases --json tagName,isLatest,assets --jq '{tag:.tagName,latest:.isLatest,assets:[.assets[].name]}'
```

期望 4 个资产：`Seal.ipa` / `Seal.ipa.sha256` / `Seal-Info.plist` / `SealTunnel-Info.plist`，
且 `isLatest=true`、tag 与 MARKETING_VERSION 对齐（如 `v1.1.8`）。

## 6. 常见坑位

- **跨仓库发布不传 `--target`**：发布命令用源仓库 SHA 当 `--target` → `422 target_commitish invalid`。
  现 workflow 已正确省略，默认指向 Seal-Releases 的 main。**别把它加回去**。
- **tag 不对齐** → 用户检测不到更新（`1.1.0` vs `v1.1.0-build4` 字符串不相等）。
- **重复发布同一 tag** 会被 `gh release create` 拒绝：先删旧 Release 或 bump 版本再发。
- **用户需要「不发版但验证」**：两条 workflow 的 `publish_release` 默认均为 false，仅生成构建产物。Release notes 的「测试中」文案不能代替发布隔离。本轮涉及 Rust/安装链路，须使用完整 `ios.yml` 且 `publish_release=false` 验证；确认运行的是本批审查分支，所有验收通过后才显式允许发布。

## 7. 发布 → 更新提示 一句话

`Seal` 内置 `UpdateChecker` 用 `CFBundleShortVersionString`(=MARKETING_VERSION) 与
GitHub Release `tag_name` 版本号比较，远端更高才提示；下载/导入失败保留源 IPA 可重试。
发对 tag、bump 对版本，用户端正常即可收到更新。