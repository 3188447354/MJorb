#!/usr/bin/env python3
"""生成「上游 SideStore ↔ Seal」的完整差异表（`docs/upstream-differences.md`）。

用法：
    python Scripts/gen-upstream-diff-table.py

为什么需要它（用户 2026-09-19）：
    「列个表，上游和 seal 完整项目，包含**所有**地方不一致的点」✓

⚠️ **先读这里的局限**（否则会误读那张表）：
    - 两边**同名文件只有 1 个** ✗ ⇒ 文件名对不上，**只能按功能映射**配对 ✓；
    - 文本相似度普遍极低（0.004–0.034）✗ ⇒ **「一字一码」在文本层面做不到** ✓；
    - 所以本表列的是「**文件层面的存在性差异**」+「**已知功能对**」，
      **不是**逐行差异 ✗。真正的对照结论在 `docs/upstream-alignment.md` 的**台账**里 ✓。
"""

from __future__ import annotations

import difflib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SEAL_DIR = ROOT / "Seal"
UPSTREAM_DIR = ROOT / "upstream" / "SideStore"
OUT = ROOT / "docs" / "upstream-differences.md"

# 与 compare-upstream.py 共用同一张功能映射表
PAIRS: dict[str, list[str]] = {
    "AnisetteProvider.swift": ["SideStore/Core/Anisette/AnisetteProvider.swift"],
    "AnisetteClient.swift": [
        "SideStore/Core/Anisette/OnDeviceAnisetteManager.swift",
        "SideStore/Core/Anisette/AnisetteServersManager.swift",
    ],
    "AnisetteServerStore.swift": ["SideStore/Core/Anisette/AnisetteServersManager.swift"],
    "ApplePortalCertificateService.swift": [
        "SideStore/Core/Operations/PipelineOperations/UpdateAppCertificateOperation.swift",
        "SideStore/Core/Operations/PipelineOperations/VerifyCertificateOperation.swift",
        "SideStore/Core/Operations/PipelineOperations/CacheSigningCertOperation.swift",
    ],
    "ApplePortalSigningService.swift": [
        "SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift",
        "SideStore/Core/Operations/PipelineOperations/RefreshAppOperation.swift",
        # ⚠️ Seal 的 `ApplePortalAppIDResolver` 是**这个文件里的嵌套类型**（没有独立文件 ✓）
        "SideStore/Core/Operations/PipelineOperations/PrepareAppExtensionBundleIDsOperation.swift",
    ],
    "MinimuxerInstallChannel.swift": [
        "SideStore/Core/Operations/PipelineOperations/InstallAppOperation.swift",
        "SideStore/Core/Operations/PipelineOperations/SendAppOperation.swift",
    ],
}

# 归类关键词（按路径片段匹配，用于把文件分组，便于阅读）
DOMAINS: list[tuple[str, tuple[str, ...]]] = [
    ("Anisette / 设备环境", ("Anisette",)),
    ("证书", ("Certificat", "Cert", "Signing")),
    ("Apple 门户 / App ID / 描述文件", ("Apple", "AppID", "Provisioning", "Portal", "Team", "Account")),
    ("签名 / 重签", ("Sign", "Rork", "MachO", "Entitlement", "Bundle")),
    ("安装 / 设备通道", ("Install", "Minimuxer", "Device", "Pairing", "Tunnel", "VPN")),
    ("续签 / 自替换", ("Renew", "SelfReplace", "SelfApp", "Refresh", "Maintenance")),
    ("日志 / 诊断", ("Log", "Diagnos", "Redact", "Trace")),
    ("UI / 界面", ("View", "Sheet", "Row", "Cell", "Settings", "Feature")),
    ("存储 / 文件", ("Storage", "File", "Store", "Archive", "IPA")),
    ("其它", ()),
]


def domain_of(path: str) -> str:
    for name, keys in DOMAINS:
        if keys and any(k in path for k in keys):
            return name
    return "其它"


def swift(root: Path) -> dict[str, Path]:
    return {p.name: p for p in root.rglob("*.swift")} if root.is_dir() else {}


def lines(p: Path) -> list[str]:
    return p.read_text(encoding="utf-8", errors="replace").splitlines()


def main() -> int:
    if not UPSTREAM_DIR.is_dir():
        print(f"❌ 找不到上游：{UPSTREAM_DIR}（见 upstream/README.md）")
        return 1

    seal = swift(SEAL_DIR)
    upstream = swift(UPSTREAM_DIR)
    shared = sorted(set(seal) & set(upstream))
    only_seal = sorted(set(seal) - set(upstream))
    only_up = sorted(set(upstream) - set(seal))

    def group(names: list[str]) -> dict[str, list[str]]:
        out: dict[str, list[str]] = {}
        for n in names:
            out.setdefault(domain_of(n), []).append(n)
        return out

    o: list[str] = []
    o.append("# 上游（SideStore）↔ Seal 的差异表\n")
    o.append("- 生成：`python Scripts/gen-upstream-diff-table.py`（**请勿手改**）")
    o.append(f"- 上游版本：`43e052cd970cb16fed6b0bb4feeaec5e5d7efae7`（2026-09-19 04:08）")
    o.append("- 对照方法与台账：`docs/upstream-alignment.md` ✓\n")
    o.append("## ⚠️ 怎么读这张表\n")
    o.append("| 事实 | 含义 |")
    o.append("|---|---|")
    o.append(f"| Seal {len(seal)} 个 Swift 文件 / 上游 {len(upstream)} 个 | — |")
    o.append(f"| **同名文件只有 {len(shared)} 个** | ✗ 文件名对不上 ⇒ 只能按**功能**配对 |")
    o.append("| 文本相似度 **0.004–0.034** | ✗ **「一字一码」在文本层面做不到** |")
    o.append("| 本表 = **文件层面的存在性差异** | ✓ 不是逐行差异 |")
    o.append("| 功能层的对照结论 | 在 `docs/upstream-alignment.md` 的**台账**里 ✓ |\n")

    # ① 已知功能对
    o.append("## 一、已知功能对（**唯一能做实质对照的地方**）\n")
    o.append("| Seal | 上游 | 相似度 | 改动行 | 台账结论 |")
    o.append("|---|---|---|---|---|")
    known = {
        "AnisetteProvider.swift": "**跟** ✓（上游每次 fetch 都重新取，从不缓存）",
        "AnisetteClient.swift": "同上（Seal 的本地/远程双通道对应上游 ODA/远程）",
        "ApplePortalCertificateService.swift": "**跟** ✓ 已实施 `ff718d9`（先创建、撞 3022 才撤销）",
        "ApplePortalSigningService.swift": "见台账（anisette 刷新 / 节流 待定）",
        "MinimuxerInstallChannel.swift": "待对照",
    }
    for seal_name, rels in sorted(PAIRS.items()):
        if seal_name not in seal:
            o.append(f"| `{seal_name}` | ⚠️ Seal 里没有这个文件 | — | — | — |")
            continue
        b = lines(seal[seal_name])
        for rel in rels:
            cand = UPSTREAM_DIR / rel
            if not cand.is_file():
                o.append(f"| `{seal_name}` | ⚠️ 上游没有 `{rel}` | — | — | — |")
                continue
            a = lines(cand)
            ratio = difflib.SequenceMatcher(None, a, b).ratio()
            changed = sum(
                1 for l in difflib.unified_diff(a, b, lineterm="")
                if l[:1] in "+-" and l[:3] not in ("+++", "---")
            )
            note = known.get(seal_name, "待对照") if rel == rels[0] else ""
            o.append(f"| `{seal_name}` | `{rel.split('/')[-1]}` | {ratio:.3f} | {changed} | {note} |")

    # ② 只在 Seal
    o.append(f"\n## 二、只在 Seal（{len(only_seal)} 个）\n")
    o.append("> 含两类：**Seal 独有功能**（上游没有 ✓）与**重命名的上游文件**（功能相同、名字不同 ✗）。\n")
    for dom, names in sorted(group(only_seal).items()):
        o.append(f"**{dom}**（{len(names)}）：")
        o.append("")
        o.append("```")
        for n in names:
            o.append(n)
        o.append("```")
        o.append("")

    # ③ 只在上游
    o.append(f"\n## 三、只在上游（{len(only_up)} 个）\n")
    o.append("> **这是最值得看的一栏** —— 上游有而 Seal 没有的东西里，"
             "可能藏着「Seal 应该实现但漏了」的功能 ✓。\n")
    for dom, names in sorted(group(only_up).items()):
        o.append(f"**{dom}**（{len(names)}）：")
        o.append("")
        o.append("```")
        for n in names:
            o.append(n)
        o.append("```")
        o.append("")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(o), encoding="utf-8", newline="")
    print(f"✓ 已生成 {OUT.relative_to(ROOT)}")
    print(f"  Seal {len(seal)} / 上游 {len(upstream)} / 同名 {len(shared)}"
          f" / 只在 Seal {len(only_seal)} / 只在上游 {len(only_up)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
