# upstream/ —— 上游源码（**只读参考，不参与 Seal 的编译**）

> **规矩（用户 2026-09-19 明确）：Seal 是二开，改签名/续签链路必须拿 SideStore
> 一字一码核对。** 本目录就是核对用的源码，**不允许改动** ✗。

## SideStore

| 项 | 值 |
|---|---|
| 仓库 | https://github.com/SideStore/SideStore |
| 版本 | `43e052cd970cb16fed6b0bb4feeaec5e5d7efae7` |
| 提交时间 | 2026-09-19 04:08:47 +0530 |
| 许可 | AGPL-3.0（**与 Seal 相同** ✓） |
| 官方描述 | *"SideStore is a fork of AltStore that doesn't require an AltServer."* |

**为什么是 SideStore**：它的定位与 Seal **完全相同**（设备内签名 + 本地隧道，不需要电脑）✓
⇒ 它是最有参考价值的上游 ✓（比 AltStore 更近）。

## 怎么更新

```bash
cd build/upstream && rm -rf SideStore && \
  git clone --depth 1 https://github.com/SideStore/SideStore.git
# 记录新版本
git -C SideStore log -1 --format="%H|%ad" --date=iso
# 同步进仓库（去掉嵌套 .git）
cd ../.. && rm -rf upstream/SideStore && cp -r build/upstream/SideStore upstream/SideStore && \
  rm -rf upstream/SideStore/.git
```

更新后**必须**：把新版本号写回本文件 + 在 `docs/upstream-alignment.md` 的台账里记一行 ✓。

## 对照入口

- **方法与台账**：`docs/upstream-alignment.md` ✓
- **一键对照工具**：`Scripts/compare-upstream.py` ✓（按文件名配对 + 逐行 diff ✓）
