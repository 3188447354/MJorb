# upstream/ —— 上游源码（**只读参考，不参与 Seal 的编译**）

> **规矩（用户 2026-09-19 明确）：Seal 是二开，改签名/续签链路必须拿上游一字一码核对。**
> 本目录就是核对用的源码，**不允许改动** ✗。
>
> **账号（用户 2026-09-19 明确）：只用 `sunuannian1`，不要其他** ✓ ——
> 本仓库只保留 `origin = sunuannian1/Trae-seal` ✓（旧的 `dmjorb/Seal` remote 已删除 ✗）。

## 上游共 5 个（用户明确：「把上游全部都拿进来」✓）

| # | 上游 | 版本 | 说明 | 许可 |
|---|---|---|---|---|
| 1 | **`SideStore/SideStore`** | `43e052cd…`（2026-09-19 04:08） | **最近的上游** —— 官方描述 *"a fork of AltStore that doesn't require an AltServer"*，**与 Seal 定位一字不差** ✓ | AGPL-3.0 |
| 2 | **`altstoreio/AltStore`** | `56854e66…`（2026-07-14 15:04） | SideStore 的父项目 ✓ | AGPL-3.0 |
| 3 | **`SideStore/AltSign`** | `35b68f1a…`（2026-08-26 16:27） | **`project.yml` 里 `AltSign` 依赖的上游** ✓（用户自己的 fork 是它的**未改动镜像** ✓） | — |
| 4 | **`mahee96/AnisetteKit`** | `db8b4102…`（2026-09-18 18:49） | **`project.yml` 里 `AnisetteKit` 依赖的上游** ✓（同上 ✓） | — |
| 5 | **`rorkai/rork-sign`** | **tag `0.6.5`**（`ce7fc756…`，2026-08-28） | **`Vendor/rork-sign/` 的上游** ✓ —— **唯一能做「一字一码」对照的地方** ✓（见下） | Apache-2.0 |

前两个与 Seal 同为 **AGPL-3.0** ✓。

### 🔴 第 5 个（rork-sign）才是真正「一字一码」的对照对象

`Vendor/rork-sign` = **上游 0.6.5 + 4 个文件的补丁** ✓ ——
完整 diff 已落盘：[`docs/upstream/rork-sign-0.6.5-vs-Vendor.diff`](../docs/upstream/rork-sign-0.6.5-vs-Vendor.diff) ✓

| 文件 | 改动 | 性质 |
|---|---|---|
| `MachO/MachOSigner.swift` | 125+ / 13- | **Seal 补丁**：`clearFairPlayCryptid`（修**启动崩溃**）+ `adjustedCodeLimit`/symtab |
| `Bundle/AppBundleSigner.swift` | 13+ / 2- | mmap |
| `Bundle/BundleSigner.swift` | 26+ / 7- | mmap（3 处） |
| `Bundle/BundleSignatureCache.swift` | 4+ / 2- | mmap |

⚠️ **对比时必须加 `--strip-trailing-cr`** ✗ —— 两边换行符不同，
不加会把整个文件算成差异（实测：2949 行 → 实际 15 行 ✓）。

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
