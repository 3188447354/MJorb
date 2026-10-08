#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""断言 arm64 产物里不含 ARMv8.1 的 LSE 原子指令（并可选校验 minOS）。

## 为什么会有这个守卫

`Seal 1.3.45` 在 **iPad 第 7 代（A10）** 上「登录 Apple ID → 点添加 → 秒退桌面」。
崩溃日志 `EXC_BAD_INSTRUCTION / Illegal instruction: 4`，出错指令是
`casal x9, x22, [x10]`（例外子码 `0xC8E9FD56` 与该指令字逐位一致）。

`casal` 属于 **ARMv8.1 的 LSE（Large System Extension）原子指令**。
**A10 是 Apple 唯一一颗「对外标示 ARMv8.1-A、实测却没实现 LSE」的芯片**
（LLVM 里 `AppleA10 = [HasV8_0aOps, …]`，不含 `FeatureLSE`；`AppleA11`/`AppleA12` 才有）。

指令来自 `AnisetteKit` 链接的 **Unicorn 预编译 xcframework**：
它的构建脚本**没有设部署目标** ⇒ clang 按 SDK 默认（iOS 26）选目标 CPU
（`clang/lib/Driver/ToolChains/Arch/AArch64.cpp: getAArch64TargetCPUByTriple`
「iOS 26 only runs on apple-a12 and later CPUs」）⇒ `apple-a12` ⇒ 生成带 LSE 的宿主代码。
所以根因不是「设备太老」，而是**预编译件用了比目标设备更新的指令集**。

## 判据

1. **零 LSE**：扫到的 arm64 Mach-O 里不得出现 `FEAT_LSE` 指令（CAS* / LDxx* / SWP* / STxx*）。
2. **minOS 不高于给定值**（传 `--max-ios-version` 时）：预编译件不得要求比 App 更高的系统，
   否则在低版本设备上照样起不来（与 `verify-rustbridge-minos.sh` 是同一类问题）。

## 实现

零依赖（不需要 capstone / xcrun / vtool），Windows 与 macOS 都能跑，用两条掩码覆盖全部 LSE 编码：

  ① CAS / CASA / CASL / CASAL / CASP*   → 固定 `bits[29:24]=001000`、`bit21=1`、`bits[14:10]=11111`
  ② LDADD/LDCLR/LDEOR/LDSET/LD{S,U}{MAX,MIN}/SWP/ST*（含 b/h/l/a/al）
                                        → 固定 `bits[29:24]=111000`、`bit21=1`、`bits[11:10]=00`
     ⚠️ `bit21=1` 是关键：`STUR/LDUR` 族的 `bits[23:21]=000`（imm9 从 bit20 起）⇒ 天然互斥。

掩码已用 capstone 做过差分实证：对 7 个真实二进制（Unicorn 官方包 3 个切片、
`Seal_1.3.8.ipa` 主程序 45MB、OpenSSL.framework 等，合计约 50MB arm64 代码）
**命中数逐条一致、零漏报零误报**。

⚠️ 只扫 `cputype == CPU_TYPE_ARM64`：fat 切片里的 x86_64 机器码若按 AArch64 解码会造出大量假命中。

用法::

    python3 Scripts/verify-no-lse.py build/Seal_1.3.x.ipa
    python3 Scripts/verify-no-lse.py --max-ios-version 17.4 Vendor/AnisetteKit/Unicorn.xcframework
"""
import argparse
import bisect
import os
import struct
import sys
import zipfile

# ── Mach-O / ar 常量 ────────────────────────────────────────────────────────
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
AR_MAGIC = b"!<arch>\n"
CPU_TYPE_ARM64 = 0x0100000C
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x02
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25

# ── LSE 编码掩码（见模块 docstring）─────────────────────────────────────────
FAMILY_CAS = "CAS/CASP"
FAMILY_ATOMIC = "原子内存操作(LDADD/LDCLR/LDEOR/LDSET/LD{S,U}{MAX,MIN}/SWP/ST*)"
LSE_MASKS = (
    (0x3F207C00, 0x08207C00, FAMILY_CAS),
    (0x3F200C00, 0x38200000, FAMILY_ATOMIC),
)
_OPC_NAMES = ("LDADD", "LDCLR", "LDEOR", "LDSET", "LDSMAX", "LDSMIN", "LDUMAX", "LDUMIN")


def lse_family(word):
    """返回 LSE 族名；不是 LSE 指令则返回 None。"""
    for mask, pattern, family in LSE_MASKS:
        if word & mask == pattern:
            return family
    return None


def lse_hint(word):
    """给一条 LSE 指令字一个可读的助记符提示（仅为可读性，不作为判据）。"""
    family = lse_family(word)
    if family is None:
        return "?"
    if family == FAMILY_CAS:
        size = {0b00: "b", 0b01: "h", 0b10: "", 0b11: ""}[(word >> 30) & 0b11]
        return "cas/casp%s" % size
    opc = (word >> 12) & 0b111
    if (word >> 15) & 1:
        return "st%s…（原子存储）" % _OPC_NAMES[opc][2:].lower()
    size = {0b00: "b", 0b01: "h", 0b10: "", 0b11: ""}[(word >> 30) & 0b11]
    aq = "a" if (word >> 23) & 1 else ""
    rl = "l" if (word >> 22) & 1 else ""
    return "%s%s%s" % (_OPC_NAMES[opc], aq + rl, size)


# ── 容器展开：ar 归档 / fat Mach-O / thin Mach-O ────────────────────────────
def iter_machos(blob, label):
    """把 ar 归档与 fat Mach-O 展开成 (label, thin_macho_bytes)。"""
    if blob[:8] == AR_MAGIC:
        off, n = 8, 0
        while off + 60 <= len(blob):
            header = blob[off:off + 60]
            rawname = header[0:16].decode("latin1").strip()
            try:
                size = int(header[48:58].decode("latin1").strip())
            except ValueError:
                break
            body = off + 60
            member = blob[body:body + size]
            name = rawname.rstrip("/")
            if rawname.startswith("#1/"):          # BSD 长名：真名在 body 开头
                name_len = int(rawname[3:])
                name = member[:name_len].rstrip(b"\0").decode("latin1")
                member = member[name_len:]
            yield from iter_machos(member, "%s(%s)" % (label, name or ("member%d" % n)))
            n += 1
            off = body + size + (size & 1)
        return
    if len(blob) < 8:
        return
    fat_magic = struct.unpack_from(">I", blob, 0)[0]
    if fat_magic in (FAT_MAGIC, FAT_MAGIC_64):
        count = struct.unpack_from(">I", blob, 4)[0]
        step = 32 if fat_magic == FAT_MAGIC_64 else 20
        for i in range(count):
            base = 8 + i * step
            if fat_magic == FAT_MAGIC_64:
                _cpu, _sub, offset, size = struct.unpack_from(">IIQQ", blob, base)
            else:
                _cpu, _sub, offset, size = struct.unpack_from(">IIII", blob, base)
            yield from iter_machos(blob[offset:offset + size], "%s[slice%d]" % (label, i))
        return
    if struct.unpack_from("<I", blob, 0)[0] == MH_MAGIC_64:
        yield label, blob


def load_commands(data):
    """yield (cmd, offset) —— 仅 64 位 Mach-O。"""
    ncpu = struct.unpack_from("<I", data, 4)[0]
    if ncpu != CPU_TYPE_ARM64:
        return
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    for _ in range(ncmds):
        if off + 8 > len(data):
            return
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        yield cmd, off
        if cmdsize <= 0:
            return
        off += cmdsize


def is_arm64(data):
    return (len(data) >= 8
            and struct.unpack_from("<I", data, 0)[0] == MH_MAGIC_64
            and struct.unpack_from("<I", data, 4)[0] == CPU_TYPE_ARM64)


def text_sections(data):
    """返回 [(addr, size, file_offset)]（__text）。"""
    out = []
    for cmd, off in load_commands(data):
        if cmd != LC_SEGMENT_64:
            continue
        # ⚠️ 目标文件（MH_OBJECT）的段名是空串，不能按 "__TEXT" 过滤段
        nsects = struct.unpack_from("<I", data, off + 64)[0]
        sect_off = off + 72
        for _ in range(nsects):
            name = data[sect_off:sect_off + 16].split(b"\0")[0].decode("latin1")
            addr, size, offset = struct.unpack_from("<QQI", data, sect_off + 32)
            if name == "__text":
                out.append((addr, size, offset))
            sect_off += 80
    return out


def symbols(data):
    """返回按地址升序的 [(addr, name)]。"""
    for cmd, off in load_commands(data):
        if cmd != LC_SYMTAB:
            continue
        sym_off, nsyms, str_off, _str_size = struct.unpack_from("<IIII", data, off + 8)
        out = []
        for i in range(nsyms):
            pos = sym_off + i * 16
            if pos + 16 > len(data):
                break
            str_index, _type, _sect, _desc, value = struct.unpack_from("<IBBHQ", data, pos)
            if value == 0 or str_index == 0:
                continue
            try:
                end = data.index(b"\0", str_off + str_index)
            except ValueError:
                continue
            out.append((value, data[str_off + str_index:end].decode("utf-8", "replace")))
        out.sort()
        return out
    return []


def min_os(data):
    """返回该 Mach-O 声明的 iOS minOS（'X.Y'），没有则 None。"""
    for cmd, off in load_commands(data):
        if cmd == LC_BUILD_VERSION:
            version = struct.unpack_from("<I", data, off + 16)[0]
            return "%d.%d" % (version >> 16, (version >> 8) & 0xFF)
        if cmd == LC_VERSION_MIN_IPHONEOS:
            version = struct.unpack_from("<I", data, off + 8)[0]
            return "%d.%d" % (version >> 16, (version >> 8) & 0xFF)
    return None


def version_tuple(text):
    parts = (text or "0").split(".")
    nums = []
    for part in parts[:3]:
        try:
            nums.append(int(part))
        except ValueError:
            return None
    while len(nums) < 3:
        nums.append(0)
    return tuple(nums)


# ── 主扫描 ─────────────────────────────────────────────────────────────────
class Report(object):
    def __init__(self):
        self.lse = []          # (label, symbol, addr, word, family)
        self.min_os = []       # (label, minos)
        self.arm64 = 0
        self.skipped = 0
        self.objects = 0
        self.unreadable = []

    def scan_macho(self, blob, label):
        if not is_arm64(blob):
            self.skipped += 1
            return
        self.arm64 += 1
        self.objects += 1
        detected = min_os(blob)
        if detected:
            self.min_os.append((label, detected))
        syms = symbols(blob)
        sym_addrs = [s[0] for s in syms]
        for addr, size, offset in text_sections(blob):
            end = min(offset + size, len(blob))
            for pos in range(offset, end - 3, 4):
                word = struct.unpack_from("<I", blob, pos)[0]
                family = lse_family(word)
                if family is None:
                    continue
                insn_addr = addr + (pos - offset)
                owner = "<unknown>"
                if sym_addrs:
                    index = bisect.bisect_right(sym_addrs, insn_addr) - 1
                    if index >= 0:
                        owner = syms[index][1]
                self.lse.append((label, owner, insn_addr, word, family))

    def scan_blob(self, blob, label):
        for inner_label, member in iter_machos(blob, label):
            self.scan_macho(member, inner_label)


def collect_ipa(ipa_path):
    """返回 [(label, bytes)] —— 只取 Payload/A 里看起来像 Mach-O 的条目。"""
    items = []
    with zipfile.ZipFile(ipa_path) as zf:
        for info in zf.infolist():
            name = info.filename
            if info.is_dir() or name.startswith("__MACOSX/") or "/." in name:
                continue
            if not name.startswith("Payload/"):
                continue
            if name.endswith((".png", ".jpg", ".jpeg", ".pdf", ".car", ".plist",
                              ".json", ".txt", ".strings", ".ttf", ".otf", ".bin")):
                continue
            try:
                with zf.open(info) as fh:
                    head = fh.read(4)
                    fh.seek(0)
                    if struct.unpack_from("<I", head, 0)[0] not in (MH_MAGIC_64,):
                        fat = struct.unpack_from(">I", head, 0)[0]
                        if fat not in (FAT_MAGIC, FAT_MAGIC_64):
                            continue
                    items.append((name, fh.read()))
            except (OSError, zipfile.BadZipFile):
                continue
    return items


def collect_path(path, report):
    """把路径展开成 (label, bytes) 列表。"""
    items = []
    if os.path.isdir(path):
        for root, _dirs, files in os.walk(path):
            for name in sorted(files):
                full = os.path.join(root, name)
                rel = os.path.relpath(full, path)
                try:
                    with open(full, "rb") as fh:
                        head = fh.read(4)
                        fh.seek(0)
                        if len(head) < 4:
                            report.skipped += 1
                            continue
                        magic_le = struct.unpack_from("<I", head, 0)[0]
                        magic_be = struct.unpack_from(">I", head, 0)[0]
                        if magic_le == MH_MAGIC_64 or magic_be in (FAT_MAGIC, FAT_MAGIC_64):
                            items.append((rel, fh.read()))
                        elif fh.read(8)[:8] == AR_MAGIC:
                            fh.seek(0)
                            items.append((rel, fh.read()))
                        else:
                            report.skipped += 1
                except OSError:
                    report.unreadable.append(full)
        return items
    if path.lower().endswith((".ipa", ".zip")):
        return collect_ipa(path)
    with open(path, "rb") as fh:
        return [(os.path.basename(path), fh.read())]


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="断言 arm64 产物不含 ARMv8.1 LSE 原子指令（可选校验 minOS）")
    parser.add_argument("paths", nargs="+", help="IPA / Mach-O / .a / 目录")
    parser.add_argument("--label", default=None, help="报告里显示的名字")
    parser.add_argument("--max-ios-version", default=None,
                        help="声明的 iOS minOS 不得高于该值（如 17.4）")
    parser.add_argument("--max-examples", type=int, default=8, help="每个族最多打印几条")
    args = parser.parse_args(argv)

    report = Report()
    for path in args.paths:
        if not os.path.exists(path):
            print("ERROR: 路径不存在: %s" % path, file=sys.stderr)
            return 2
        try:
            items = collect_path(path, report)
        except (OSError, zipfile.BadZipFile) as exc:
            print("ERROR: 无法读取 %s: %s" % (path, exc), file=sys.stderr)
            return 2
        for label, blob in items:
            report.scan_blob(blob, label)

    label = args.label or ", ".join(args.paths)
    print("[verify-no-lse] %s" % label)
    print("  arm64 Mach-O=%d（跳过非 arm64/非 Mach-O=%d）"
          % (report.arm64, report.skipped))

    failures = []
    if report.lse:
        by_family = {}
        for item in report.lse:
            by_family[item[4]] = by_family.get(item[4], 0) + 1
        shown = {}
        print("  ❌ LSE 指令 %d 条：" % len(report.lse))
        for family, count in sorted(by_family.items(), key=lambda kv: -kv[1]):
            print("       %s : %d" % (family, count))
        for item in report.lse:
            obj, owner, addr, word, family = item
            if shown.get(family, 0) >= args.max_examples:
                continue
            shown[family] = shown.get(family, 0) + 1
            print("       %s @0x%x  0x%08X  %s  ← %s"
                  % (obj, addr, word, lse_hint(word), owner))
        failures.append("发现 %d 条 ARMv8.1 LSE 原子指令（A10/A10X 会以 SIGILL 秒退）"
                        % len(report.lse))

    if args.max_ios_version:
        limit = version_tuple(args.max_ios_version)
        for obj, detected in report.min_os:
            value = version_tuple(detected)
            if limit and value and value > limit:
                print("  ❌ minOS 过高: %s 声明 iOS %s（上限 %s）"
                      % (obj, detected, args.max_ios_version))
                failures.append("%s 的 minOS 高于 %s" % (obj, args.max_ios_version))

    if report.unreadable:
        print("  ⚠️  无法读取 %d 个文件" % len(report.unreadable))

    if failures:
        print("  FAIL: " + "；".join(sorted(set(failures))))
        return 1
    print("  OK: arm64 产物零 LSE%s"
          % ("，minOS ≤ %s" % args.max_ios_version if args.max_ios_version else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
