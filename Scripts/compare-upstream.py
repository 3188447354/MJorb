#!/usr/bin/env python3
"""把 Seal 的源码与上游 SideStore **逐行对照**，产出「一字一码」的核对清单。

用法：
    python Scripts/compare-upstream.py            # 概览 + 最值得对齐的候选
    python Scripts/compare-upstream.py --file X   # 看某个文件的完整 diff

背景（用户 2026-09-19 明确）：
    **Seal 是二开，改签名/续签链路必须拿 SideStore 一字一码核对。**
    上游源码在 `upstream/SideStore/`（只读，见 `upstream/README.md`）。

判读方式：
    - **完全相同** ⇒ 已对齐，不用动 ✓
    - **差异很小** ⇒ **最值得对齐的候选** ✓（说明 Seal 只偏了一点点）
    - **差异很大** ⇒ 要么 Seal 已大改（看是不是有意为之），要么本来就不同源
    - **只在 Seal / 只在上游** ⇒ 记录，别急着改
"""

from __future__ import annotations

import argparse
import difflib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SEAL_DIR = ROOT / "Seal"
UPSTREAM_DIR = ROOT / "upstream" / "SideStore"
SEAL_TESTS = ROOT / "SealTests"


# ── 功能映射表：Seal 的文件 ↔ 上游的文件 ────────────────────────────────────
#
# ⚠️ **为什么需要这张表**（2026-09-19 实测）：两边**同名文件只有 1 个** ✗ ——
# Seal 的命名是自建的一套（`AnisetteClient` / `AccountSecret` …），
# 而上游是 `ALT*` / AltStore 风格 ⇒ **按文件名配对完全对不上** ✗。
# ⇒ 只能按**功能**配对 ✓。新增对照时往这里加一行。
PAIRS: dict[str, list[str]] = {
    # anisette
    "AnisetteProvider.swift": ["AnisetteProvider.swift"],
    "AnisetteClient.swift": [
        "SideStore/Core/Anisette/OnDeviceAnisetteManager.swift",
        "SideStore/Core/Anisette/AnisetteServersManager.swift",
    ],
    "AnisetteServerStore.swift": ["SideStore/Core/Anisette/AnisetteServersManager.swift"],
    # 证书
    "ApplePortalCertificateService.swift": [
        "SideStore/Core/Operations/PipelineOperations/UpdateAppCertificateOperation.swift",
        "SideStore/Core/Operations/PipelineOperations/VerifyCertificateOperation.swift",
        "SideStore/Core/Operations/PipelineOperations/CacheSigningCertOperation.swift",
    ],
    # App ID / 描述文件
    "ApplePortalAppIDResolver.swift": [
        "SideStore/Core/Operations/PipelineOperations/PrepareAppExtensionBundleIDsOperation.swift",
    ],
    "ApplePortalSigningService.swift": [
        "SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift",
        "SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift",
    ],
    # 安装
    "MinimuxerInstallChannel.swift": [
        "SideStore/Core/Operations/PipelineOperations/InstallAppOperation.swift",
        "SideStore/Core/Operations/PipelineOperations/SendAppOperation.swift",
    ],
}


def swift_files(root: Path) -> dict[str, Path]:
    """按**文件名**建索引（上游与 Seal 的目录结构不同，只能靠文件名配对）。"""
    if not root.is_dir():
        return {}
    return {p.name: p for p in root.rglob("*.swift")}


def read_lines(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", help="只看某个文件名（如 AnisetteProvider.swift）")
    parser.add_argument("--top", type=int, default=30, help="概览里列多少个候选")
    args = parser.parse_args()

    if not UPSTREAM_DIR.is_dir():
        print(f"❌ 找不到上游源码：{UPSTREAM_DIR}")
        print("   先按 upstream/README.md 里的命令把它拿进来。")
        return 1

    seal = swift_files(SEAL_DIR)
    seal.update(swift_files(SEAL_TESTS))
    upstream = swift_files(UPSTREAM_DIR)
    print(f"Seal: {len(seal)} 个 Swift 文件 | SideStore: {len(upstream)} 个\n")

    if args.file:
        name = args.file
        if name not in seal:
            print(f"❌ Seal 里没有 {name}")
            return 1
        # 优先用**功能映射表**找上游对应文件；没有映射就退回同名
        counterparts = PAIRS.get(name, [name])
        found = False
        for rel in counterparts:
            cand = UPSTREAM_DIR / rel
            if not cand.is_file():
                print(f"⚠️  映射表里的上游文件不存在：{rel}")
                continue
            found = True
            diff = list(difflib.unified_diff(
                read_lines(cand), read_lines(seal[name]),
                fromfile=f"upstream/{rel}", tofile=f"Seal/{name}", lineterm="",
            ))
            print(f"\n{'=' * 70}\n=== Seal/{name}  ↔  upstream/{rel}\n{'=' * 70}")
            print("\n".join(diff) if diff else "完全相同 ✓")
        if not found:
            print(f"❌ 没有可对照的上游文件（映射表：{counterparts}）")
            return 1
        return 0

    shared = sorted(set(seal) & set(upstream))
    identical, candidates = [], []
    for name in shared:
        a, b = read_lines(upstream[name]), read_lines(seal[name])
        if a == b:
            identical.append(name)
            continue
        ratio = difflib.SequenceMatcher(None, a, b).ratio()
        changed = sum(1 for l in difflib.unified_diff(a, b, lineterm="") if l[:1] in "+-" and l[:3] not in ("+++", "---"))
        candidates.append((ratio, changed, len(a), len(b), name))

    print(f"=== 同名文件 {len(shared)} 个：完全相同 {len(identical)} 个，有差异 {len(candidates)} 个 ===\n")
    print(f"--- 差异**最小**的 {args.top} 个（最值得对齐的候选 ✓）---")
    print(f"{'相似度':>7} {'改动行':>6} {'上游行':>6} {'Seal行':>6}  文件")
    for ratio, changed, la, lb, name in sorted(candidates, reverse=True)[: args.top]:
        print(f"{ratio:7.3f} {changed:6d} {la:6d} {lb:6d}  {name}")

    only_up = sorted(set(upstream) - set(seal))
    only_seal = sorted(set(seal) - set(upstream))
    print(f"\n--- 只在上游（{len(only_up)} 个）---")
    for name in only_up[:15]:
        print("   ", name)
    print(f"\n--- 只在 Seal（{len(only_seal)} 个，含 Seal 独有功能）---")
    for name in only_seal[:15]:
        print("   ", name)

    print("\n=== 按**功能映射表**的对照（这才是「一字一码」该看的地方 ✓）===")
    print(f"{'相似度':>7} {'改动行':>6}   Seal 文件  ↔  上游文件")
    for seal_name, rels in sorted(PAIRS.items()):
        if seal_name not in seal:
            continue
        b = read_lines(seal[seal_name])
        for rel in rels:
            cand = UPSTREAM_DIR / rel
            if not cand.is_file():
                continue
            a = read_lines(cand)
            ratio = difflib.SequenceMatcher(None, a, b).ratio()
            changed = sum(
                1 for l in difflib.unified_diff(a, b, lineterm="")
                if l[:1] in "+-" and l[:3] not in ("+++", "---")
            )
            print(f"{ratio:7.3f} {changed:6d}   {seal_name}  ↔  {rel.split('/')[-1]}")

    print("\n看某个文件的完整 diff：python Scripts/compare-upstream.py --file <文件名>")
    return 0


if __name__ == "__main__":
    sys.exit(main())
