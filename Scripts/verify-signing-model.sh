#!/usr/bin/env bash
# =============================================================================
# Seal 签名三改动 · macOS 验证脚本（2026-09-16）
# 用法：在 macOS 仓库根目录执行  bash Scripts/verify-signing-model.sh
# 它会：构建 + 单测 + 未签名 IPA 校验，最后打印真机回归步骤清单。
# 注意：真机部分无法自动化，脚本只做"构建/单测/IPA"并在最后提示人工步骤。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
fail(){ printf '\033[1;31m  ✘ %s\033[0m\n' "$*"; exit 1; }
note(){ printf '\033[1;33m  · %s\033[0m\n' "$*"; }

# --- 前置检查：确认在 macOS && 有 xcodebuild/swift -------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "此脚本必须在 macOS 上运行（当前: $(uname -s)）。"
fi
command -v xcodegen >/dev/null || note "未检测到 xcodegen，将跳过 xcodegen generate（如有需要请 brew install xcodegen）"
command -v xcodebuild >/dev/null || fail "缺少 xcodebuild，请先安装 Xcode。"

# --- 1. 生成项目 ------------------------------------------------------------
if command -v xcodegen >/dev/null; then
    log "1/4 xcodegen generate"
    xcodegen generate || fail "xcodegen generate 失败"
    ok "xcodegen generate"
else
    note "跳过 xcodegen generate（未安装 xcodegen）"
fi

# --- 2. 单元测试（含 CertificateTakeoverPolicy / SignedIPAIdentityReader / SelfReplacement）---
log "2/4 bash Scripts/ci-test.sh"
bash Scripts/ci-test.sh || fail "ci-test.sh 失败"
ok "ci-test.sh"

# --- 3. rork-sign 包测试 -----------------------------------------------------
log "3/4 swift test --package-path Vendor/rork-sign"
swift test --package-path Vendor/rork-sign || fail "rork-sign 测试失败"
ok "rork-sign"

# --- 4. 未签名 IPA 构建 + 校验 -----------------------------------------------
log "4/4 未签名 IPA 校验"
SEAL_IPA_CONFIGURATION=Release SEAL_SKIP_XCODEGEN=1 bash Scripts/build-unsigned-ipa.sh \
    || fail "build-unsigned-ipa.sh 失败"
bash Scripts/verify-ipa.sh build/Seal_*.ipa || fail "verify-ipa.sh 失败"
ok "未签名 IPA 构建与校验"

# --- 汇总 ----------------------------------------------------------------
ok "构建 / 单测 / IPA 校验全部通过。剩余真机回归请按 docs/qa/2026-09-16-signing-model-verification.md 执行。"

echo
echo "======================================================================"
echo " 真机回归步骤（自动化脚本到此结束，以下为人工清单）"
echo "======================================================================"
echo
echo "A. 回归样本（微信 / 黄豆短剧 / LCSign / lanmanga）每条都要："
echo "   1) 新建记录 → 选账号 → 签名成功入库"
echo "   2) 覆盖安装成功、App 可打开"
echo "   3) 签出 Bundle ID 带 .seal.<TeamID> 后缀（Seal 自身除外）"
echo "   4) 续签复用自身 mappedBundleIdentifier，ID 不变"
echo "   5) 到期日前正常续签，不被设备槽位/证书占用误拦"
echo "   6) 安装日志脱敏（无 Apple ID 明文 / 完整序列号）"
echo
echo "B. C1 专项 — 第三方签名 Seal 识别："
echo "   1) 用 Sideloadly/爱思把 Seal 签到真机"
echo "   2) 证书页能读到当前 Seal 真实 signer（末4位记 Notes）"
echo "   3) 不应再报 inconsistentArchitectures / SEAL-CERT-232"
echo "   4) 走完一次自续签接管，新 Seal 确认真实签名者为 B"
echo "   5) 新 Seal 数据容器仍在"
echo
echo "C. C3 专项 — 单槽位接管（T1-T5）："
echo "   T1 空槽位→直接建B不动A        T2 有A+C残留→撤C建B"
echo "   T2b B创建失败→A仍可启动        T3 signer未知→报SEAL-CERT-232"
echo "   T4 只剩A满槽位→阻断等电脑      T5 全程不并行建第二张卡"
echo
echo "D. C2 现状回归：同Team重复签Same App→Bundle ID确定；不同Team→后缀隔离。"
echo
echo "E. 脱敏记录：证书只记角色(A/B/C)+序列号末4位；事务只记ID末8位。"
echo
echo "======================================================================"