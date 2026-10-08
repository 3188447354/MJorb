#!/usr/bin/env bash
# 确保 Vendor/AnisetteKit/Unicorn.xcframework 是**不含 ARMv8.1 LSE 原子指令**的版本。
#
# ── 为什么 ────────────────────────────────────────────────────────────────────
# 崩溃现象：Seal 在 **iPad 第 7 代（A10，iOS 18.7.10）** 上「登录 Apple ID → 点添加 → 秒退」。
#   崩溃日志 `EXC_BAD_INSTRUCTION / Illegal instruction: 4`，出错指令 `casal x9, x22, [x10]`
#   （例外子码 `0xC8E9FD56` 与该指令字逐位一致）。
#
# 根因：`casal` 是 **ARMv8.1 的 LSE 原子指令**，而 **A10 是 Apple 唯一一颗「对外标示
#   ARMv8.1-A、实测却没实现 LSE」的芯片**（LLVM：`AppleA10 = [HasV8_0aOps, …]`，
#   不含 `FeatureLSE`；`AppleA11` 起才有）。
#   这些指令来自上游 Unicorn 预编译包的**宿主代码**（`_cpu_exec_aarch64` / `cputlb.c` 等）——
#   它的构建脚本 `build_xcframework.sh` **没有设部署目标**，于是 clang 按 SDK 默认版本
#   （Xcode 26 ⇒ iOS 26）选目标 CPU：
#       clang/lib/Driver/ToolChains/Arch/AArch64.cpp: getAArch64TargetCPUByTriple
#         // iOS 26 only runs on apple-a12 and later CPUs.
#         if (!Triple.isOSVersionLT(26)) return "apple-a12";      ← 带 LSE
#   ⇒ 生成带 LSE 的 arm64 机器码 ⇒ 在 A10 上走到就 SIGILL。
#
# 所以这不是「设备太老」，而是**预编译件用了比目标设备更新的指令集**。
# 本仓库最低支持 iOS 17.4，而 17.4 能跑的最老芯片正是 **A10 / A10X**
# （iPad 第 6/7 代、iPad Pro 10.5"/12.9" 2017）⇒ 库的指令集基线就必须钉在 A10。
#
# ── 做法 ──────────────────────────────────────────────────────────────────────
# 从 pinned commit 拉 Unicorn 源码，用 **`-mcpu=apple-a10`** 构建两个切片
# （ios device + ios simulator），再用 `Scripts/verify-no-lse.py` **当场量** LSE=0 与 minOS，
# 通过后才写指纹。指纹不符 / 缺件 ⇒ 重编（fail-safe：改了源码或参数却忘了回传产物，
# 永远不会让 CI/打包用到过期或带 LSE 的库）。
#
# ⚠️ 与 `ensure-rustbridge.sh` 同一套路数；区别是本脚本额外把「指令集基线」当成产物的
#    一等质量门，而不是只看 minOS（见 DEBUG_LOG.md「常犯坑位」）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SEAL_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PACKAGE_DIR="$ROOT/Vendor/AnisetteKit"
XCFRAMEWORK="$PACKAGE_DIR/Unicorn.xcframework"
FINGERPRINT_FILE="$XCFRAMEWORK/.source-fingerprint"
WORK_ROOT="$ROOT/build/unicorn"
SRC_DIR="$WORK_ROOT/src"

# ── 可调参数（改动任意一项都会让指纹失效并触发重编）────────────────────────────
# pinned 源码 = 上游 release `2.1.4-multiarch` 所对应的提交，
# 也就是**当前线上包里那个带 LSE 的包所用的同一份源码** ⇒ 除了指令集基线之外，
# 行为与现状完全一致（最小改动原则）。
UNICORN_REPO="${UNICORN_REPO:-https://github.com/mahee96/unicorn}"
UNICORN_REF="${UNICORN_REF:-62d0155ffd4c886d14cf7aa26b7f3ed759617c71}"
# Seal 最低支持 iOS 17.4 ⇒ 最老设备是 A10/A10X ⇒ 目标 CPU 钉成 apple-a10（无 LSE）。
UNICORN_TARGET_CPU="${UNICORN_TARGET_CPU:-apple-a10}"
IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.4}"
UNICORN_LOGGING="${UNICORN_LOGGING:-ON}"
# ⚠️ 只出两个 arm64 单架构切片：`-mcpu=apple-a10` 对 x86_64 切片无意义（会直接报错），
#    而本仓 CI 固定跑在 macos-26（Apple Silicon）+ Xcode 26.5 ⇒ 模拟器只需 arm64。
BUILD_VERSION="3"

if command -v shasum >/dev/null 2>&1; then
  hash_stdin() { shasum -a 256 | cut -d' ' -f1; }
elif command -v sha256sum >/dev/null 2>&1; then
  hash_stdin() { sha256sum | cut -d' ' -f1; }
else
  echo "需要 shasum 或 sha256sum 才能计算指纹" >&2
  exit 2
fi

current="$(
  {
    printf 'ref=%s\n' "$UNICORN_REF"
    printf 'cpu=%s\n' "$UNICORN_TARGET_CPU"
    printf 'minos=%s\n' "$IPHONEOS_DEPLOYMENT_TARGET"
    printf 'logging=%s\n' "$UNICORN_LOGGING"
    printf 'build_version=%s\n' "$BUILD_VERSION"
    # 脚本自身的内容也算进指纹：改了构建参数/流程而忘记回传产物时会当场重编。
    hash_stdin < "$SCRIPT_DIR/ensure-unicorn.sh"
  } | hash_stdin
)"

stored=""
if [[ -f "$FINGERPRINT_FILE" ]]; then
  stored="$(tr -d '[:space:]' < "$FINGERPRINT_FILE" || true)"
fi

slices_present=true
for slice in ios-arm64 ios-arm64-simulator; do
  [[ -f "$XCFRAMEWORK/$slice/libunicorn.a" ]] || slices_present=false
done

if $slices_present && [[ -n "$stored" && "$current" == "$stored" ]]; then
  echo "Unicorn up-to-date (fingerprint ${current:0:12}); reusing vendored xcframework."
  # 即便复用也复核一次：产物在仓库里被替换/损坏时立刻暴露，而不是等到真机 SIGILL。
  python3 "$SCRIPT_DIR/verify-no-lse.py" \
    --label "Vendor/AnisetteKit/Unicorn.xcframework (reuse)" \
    --max-ios-version "$IPHONEOS_DEPLOYMENT_TARGET" \
    "$XCFRAMEWORK"
  exit 0
fi

echo "Unicorn stale/missing (source=${current:0:12} stored=${stored:0:12} slices=$slices_present); rebuilding from source..."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Unicorn rebuild requires macOS (xcrun clang + xcodebuild -create-xcframework)." >&2
  echo "本机是 Windows/CI 外的环境时，请直接使用仓库里已 vendored 的 Unicorn.xcframework。" >&2
  exit 2
fi
for tool in cmake xcrun xcodebuild git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required to rebuild Unicorn" >&2; exit 2; }
done

# ── 1. 取源码（pinned commit）──────────────────────────────────────────────────
if [[ ! -d "$SRC_DIR/.git" ]]; then
  rm -rf "$SRC_DIR"
  mkdir -p "$(dirname "$SRC_DIR")"
  git clone --quiet "$UNICORN_REPO" "$SRC_DIR"
fi
git -C "$SRC_DIR" fetch --quiet origin "$UNICORN_REF" 2>/dev/null || git -C "$SRC_DIR" fetch --quiet origin
git -C "$SRC_DIR" checkout --quiet --force "$UNICORN_REF"
actual_ref="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [[ "$actual_ref" != "$UNICORN_REF" ]]; then
  echo "Unicorn source ref mismatch: expected $UNICORN_REF got $actual_ref" >&2
  exit 2
fi
echo "Unicorn source at $actual_ref"

# ── 2. 逐切片构建 ─────────────────────────────────────────────────────────────
patch_config_host() {
  # 上游为 iOS 目标打的同一个补丁：非 macOS 目标不能有 HAVE_PTHREAD_JIT_PROTECT。
  local cfg="$1/config-host.h"
  if [[ -f "$cfg" ]]; then
    sed -i '' \
      's/#define HAVE_PTHREAD_JIT_PROTECT 1/\/* HAVE_PTHREAD_JIT_PROTECT removed for non-macOS target *\//' \
      "$cfg"
    echo "    patched config-host.h"
  fi
}

build_slice() {
  local slice="$1" sysroot="$2" extra="$3"
  local build_dir="$WORK_ROOT/build_${slice//-/_}"
  local out_dir="$WORK_ROOT/out/$slice"

  echo "==> building Unicorn for ${slice} (sysroot=${sysroot})"
  rm -rf "$build_dir" "$out_dir"
  mkdir -p "$build_dir" "$out_dir"

  local cc
  cc="$(xcrun -sdk "$sysroot" -find clang)"

  # 参数与上游 build_xcframework.sh 对齐，只改两处（就是修复本体）：
  #   ① 显式部署目标（否则 clang 按 SDK 默认版本选 apple-a12）
  #   ② -mcpu=apple-a10（A10 无 LSE ⇒ 原子操作降级为 ldxr/stxr 循环）
  cmake -S "$SRC_DIR" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DUNICORN_ARCH=aarch64 \
    -DUNICORN_BUILD_TESTS=OFF \
    -DUNICORN_INSTALL=OFF \
    -DUNICORN_LOGGING="$UNICORN_LOGGING" \
    -DUNICORN_ENABLE_TCI=ON \
    -DCMAKE_C_COMPILER="$cc" \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IPHONEOS_DEPLOYMENT_TARGET" \
    -DCMAKE_C_FLAGS="-mcpu=$UNICORN_TARGET_CPU" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY

  patch_config_host "$build_dir"
  cmake --build "$build_dir" --config Release -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

  cp "$build_dir/libunicorn.a" "$out_dir/libunicorn.a"
  echo "    ${slice} done: $(du -h "$out_dir/libunicorn.a" | cut -f1)"
}

build_slice ios-arm64           iphoneos          ""
build_slice ios-arm64-simulator iphonesimulator   ""

# ── 3. 组装 XCFramework ───────────────────────────────────────────────────────
echo "==> creating Unicorn.xcframework"
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework \
  -library "$WORK_ROOT/out/ios-arm64/libunicorn.a" -headers "$SRC_DIR/include" \
  -library "$WORK_ROOT/out/ios-arm64-simulator/libunicorn.a" -headers "$SRC_DIR/include" \
  -output "$XCFRAMEWORK"

# ── 4. 质量门：指令集基线（LSE=0）+ minOS ─────────────────────────────────────
# 这一道是本次事故的核心教训：**只声明部署目标不够，必须量产物的机器码**。
echo "==> verifying instruction-set baseline"
python3 "$SCRIPT_DIR/verify-no-lse.py" \
  --label "Vendor/AnisetteKit/Unicorn.xcframework (fresh)" \
  --max-ios-version "$IPHONEOS_DEPLOYMENT_TARGET" \
  "$XCFRAMEWORK"

# ── 5. 通过才写指纹 ───────────────────────────────────────────────────────────
mkdir -p "$XCFRAMEWORK"
printf '%s\n' "$current" > "$FINGERPRINT_FILE"

echo "Unicorn rebuilt and verified (fingerprint ${current:0:12}, cpu=$UNICORN_TARGET_CPU, minOS=$IPHONEOS_DEPLOYMENT_TARGET)."
