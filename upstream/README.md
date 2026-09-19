# upstream/ —— 上游源码（**只读参考，不参与 Seal 的编译**）

> **规矩（用户 2026-09-19 明确）：Seal 是二开，改签名/续签链路必须拿上游一字一码核对。**
> 本目录就是核对用的源码，**不允许改动** ✗。
>
> **账号（用户 2026-09-19 明确）：只用 `sunuannian1`，不要其他** ✓ ——
> 本仓库只保留 `origin = sunuannian1/Trae-seal` ✓（旧的 `dmjorb/Seal` remote 已删除 ✗）。

## 上游两个（用户明确：「上游就是 sidestore 和 altstore」）

| 上游 | 版本 | 大小 | 说明 |
|---|---|---|---|
| **SideStore** | `43e052cd970cb16fed6b0bb4feeaec5e5d7efae7`（2026-09-19 04:08） | 28 MB / 660 文件 | **最近的上游** —— 官方描述 *"a fork of AltStore that doesn't require an AltServer"*，**与 Seal 定位一字不差** ✓ |
| **AltStore** | `56854e66fef2eac32dad88dcbad1dc131d430e60`（2026-07-14 15:04） | 151 MB / 911 文件 | SideStore 的父项目 ✓ |

两者都是 **AGPL-3.0** ✓（**与 Seal 相同** ✓）。

## 怎么更新

```bash
cd build/upstream
rm -rf SideStore AltStore
git clone --depth 1 https://github.com/SideStore/SideStore.git
git clone --depth 1 https://github.com/altstoreio/AltStore.git
# 记录新版本
git -C SideStore log -1 --format="%H|%ad" --date=iso
git -C AltStore  log -1 --format="%H|%ad" --date=iso
# 同步进仓库（去掉嵌套 .git）
cd ../.. && rm -rf upstream/SideStore upstream/AltStore
cp -r build/upstream/SideStore upstream/SideStore && rm -rf upstream/SideStore/.git
cp -r build/upstream/AltStore  upstream/AltStore  && rm -rf upstream/AltStore/.git
```

更新后**必须**：把新版本号写回本文件 + 在 `docs/upstream-alignment.md` 的台账里记一行 ✓。

## 对照工具与产物

| 文件 | 用途 |
|---|---|
| `docs/upstream-alignment.md` | **对照台账**（结论 + 方法 + 拉取命令）✓ —— **改签名链路前必查** ✓ |
| `docs/upstream-differences.md` | **完整差异表**（脚本生成，请勿手改 ✓） |
| `Scripts/compare-upstream.py` | 概览 / `--file <Seal 文件名>` 看完整 diff ✓ |
| `Scripts/gen-upstream-diff-table.py` | 重新生成差异表 ✓ |

## ⚠️ 一个必须先知道的事实（实测）

**两边同名文件只有 1 个**（`AnisetteProvider.swift`）✗，
**文本相似度 0.004–0.121** ✗
⇒ **「逐字符对照」在文本层面做不到** ✓ ——
⇒ 能做的、也正在做的是**按功能逐条核对**（台账里已有 3 条结论 ✓）。
