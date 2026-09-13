#!/usr/bin/env python3
"""Small source-regression guard. This is NOT compilation or a runtime test."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]

def read(path):
    return (ROOT / path).read_text(encoding="utf-8-sig")

def section(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]

def violations(load=read):
    failures = []
    checks = 0
    def check(ok, message):
        nonlocal checks
        checks += 1
        if not ok:
            failures.append(message)

    rust = load("Vendor/Minimuxer/RustBridge/src/idevice_support/install.rs")
    install = section(rust, "pub(crate) async fn run_install_chain", "fn is_missing_package_path")
    check(".uninstall(" not in install, "R01: installation recovery must not uninstall")
    swift = load("Vendor/Minimuxer/Sources/Install.swift")
    legacy = section(swift, "public class LockDownInstall", "public class RPInstall")
    legacy = section(legacy, "public func installIpa", "public func removeApp")
    check(".uninstall(" not in legacy, "R01: legacy installation must not uninstall")

    signing = load("Seal/Core/Signing/SigningCoordinator.swift")
    install = section(signing, "private func installSignedIPA(", "private func removeStaleProfiles(")
    check("InstalledAppDeviceVerifier.isInstalled" not in install,
          "R02: lookup cannot turn failed replacement into success")
    portal = load("Seal/Infrastructure/Signing/ApplePortalSigningService.swift")
    check("recoverCertificateCapacityAndCreate" not in portal,
          "R03: do not auto-revoke other certificates on capacity failure")
    create = section(portal, "private func createSigningIdentity(", "private func waitForCreatedCertificate(")
    check("revokeCertificate(" not in create and "cleanUpNewCertificate(" in create,
          "R03: only cleanup of this operation's new certificate is allowed")

    parser = load("Seal/Core/Import/IPAParserService.swift")
    check("nestedData" not in parser and 'code: "SEAL-IPA-101b"' in parser,
          "Import: nested wrappers must not be buffered or committed as inner IPAs")
    validator = load("Seal/Infrastructure/Installation/SignedArtifactValidator.swift")
    check('guard let executableName = plist["CFBundleExecutable"]' in validator
          and "$0.uncompressedSize > 0" in validator,
          "R12: executable declaration and nonempty file must be required")
    operation = load("Seal/Application/OperationCoordinator.swift")
    check("guard Task.isCancelled == false else { return nil }" in operation,
          "Operation: cancelled waiters must not acquire a lease")
    apps = load("Seal/Features/Apps/AppsViewModel.swift")
    retry = section(apps, "func refreshFailedItems()", "func cancelBatchRefresh()")
    check("startBatchRefresh()" not in retry,
          "R10: failed-only retry must never silently rerun every app")

    # Copy tells users to revoke a certificate in-app, so the UI must actually offer an entry.
    # Regression: 7 strings promised "在「我的」页面撤销" while no view ever called revokeCertificate.
    ui = load("Seal/Features/Settings/SigningCertificateSettingsView.swift")
    check("revokeCertificate(" in ui,
          "Copy: in-app certificate revocation must have a real UI entry")

    # 指引「撤销证书」的 recovery 文案必须点名真实入口（「我的」→「签名证书」）。
    # 只写「我的」会把用户丢在 Apple ID 列表上，还要自己猜下一步点哪里。
    stale_copy = []
    for path in ("Seal/Core/Signing/SigningCoordinator.swift",
                 "Seal/Infrastructure/Signing/ApplePortalCertificateService.swift",
                 "Seal/Infrastructure/Signing/ApplePortalSigningService.swift"):
        for line in load(path).splitlines():
            if "撤销" in line and "recovery:" in line and "「签名证书」" not in line:
                stale_copy.append(path + " -> " + line.strip())
    check(not stale_copy,
          "Copy: revoke guidance must name 我的 -> 签名证书 (" + " | ".join(stale_copy) + ")")

    versions = re.findall(r"MARKETING_VERSION:\s*(\S+)", load("project.yml"))
    check(len(versions) == 2 and len(set(versions)) == 1,
          "Release: Seal and SealTunnel versions must match")
    for workflow in ("ios.yml", "ios-release.yml"):
        text = load(".github/workflows/" + workflow)
        check("inputs.publish_release == true" in text
              and re.search(r"publish_release:[\s\S]*?default: false", text) is not None,
              workflow + ": publishing must be explicit and default off")
        check(re.search(r"\n  publish-release:[\s\S]{0,600}?\n    if: github\.event_name == 'workflow_dispatch'",
                        text) is not None,
              workflow + ": publish job must stay gated to workflow_dispatch (never run on push)")
        check('${TAG#v}' in text and '!= "$VER"' in text,
              workflow + ": release tag must match built IPA version")

    # UI 回归已从 build-package 拆成独立的 swift-regression job。它一旦脱离发布依赖，
    # 发布就可能在回归尚未跑完时把包发出去。测试失败原因必须能直接看到（GitHub 原始日志要登录，
    # 注解不用），否则只会留下「exit 65」这种无法定位的失败。
    ios = load(".github/workflows/ios.yml")
    check(re.search(r"\n  publish-release:[\s\S]{0,600}?\n    needs: \[[^\]]*swift-regression", ios) is not None,
          "ios.yml: publish must wait for the swift-regression gate")
    check("tee build/TestLog.txt" in ios and "::error::" in ios,
          "ios.yml: test failures must be surfaced as annotations")

    # 任何构建 App 的 job 都必须先跑 ensure-rustbridge.sh：本仓允许预编译 RustBridge.xcframework
    # 落后于 Rust 源码（脚本按源码指纹当场重编）。漏跑就会链接到缺符号的旧库，
    # 报一堆 `_rust_bridge_*` undefined symbols —— 2026-09-14 拆分 job 时真实踩到。
    check("ensure-rustbridge.sh" in section(ios, "\n  build-package:", "\n  swift-regression:"),
          "ios.yml: build-package must run ensure-rustbridge.sh")
    check("ensure-rustbridge.sh" in section(ios, "\n  swift-regression:", "\n  rork-sign-tests:"),
          "ios.yml: swift-regression must run ensure-rustbridge.sh")
    return checks, failures

def main():
    count, failures = violations()
    # Mutation checks prove the key deletion guards actually reject their old patterns.
    mutations = [
        ("Vendor/Minimuxer/RustBridge/src/idevice_support/install.rs",
         "    let candidates = install_candidates(bundle_id, file_name);",
         "    let _ = inst_client.uninstall(bundle_id, None).await;\n    let candidates = install_candidates(bundle_id, file_name);",
         "R01:"),
        ("Seal/Core/Signing/SigningCoordinator.swift", "        var updated = app\n",
         "        var updated = app\n        // InstalledAppDeviceVerifier.isInstalled\n", "R02:"),
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "actor ApplePortalSigningService {",
         "actor ApplePortalSigningService {\n// recoverCertificateCapacityAndCreate\n", "R03:"),
        (".github/workflows/ios.yml",
         "if: github.event_name == 'workflow_dispatch' && inputs.publish_release == true",
         "if: inputs.publish_release == true",
         "ios.yml: publish job"),
        (".github/workflows/ios.yml",
         "needs: [build-package, rork-sign-tests, swift-regression]",
         "needs: [build-package, rork-sign-tests]",
         "ios.yml: publish must wait"),
        (".github/workflows/ios.yml",
         "run: bash Scripts/ensure-rustbridge.sh",
         "run: echo skipped",
         "ios.yml: build-package must run ensure-rustbridge"),
        ("Seal/Infrastructure/Signing/ApplePortalCertificateService.swift",
         'recovery: "在「我的」→「签名证书」中撤销一个旧签名证书后重试"',
         'recovery: "在「我的」页面撤销一个旧签名证书后重试"',
         "Copy: revoke guidance"),
    ]
    for path, old, new, expected in mutations:
        original = read(path)
        if old not in original:
            failures.append("Mutation anchor missing: " + path)
            continue
        changed = original.replace(old, new, 1)
        _, mutated_failures = violations(lambda p: changed if p == path else read(p))
        if not any(item.startswith(expected) for item in mutated_failures):
            failures.append("Guard failed mutation check: " + expected)
    print("Source regression checks: " + str(count))
    print("Guard mutation checks: " + str(len(mutations)))
    if failures:
        for failure in failures:
            print("FAIL: " + failure)
        return 1
    print("PASS. Static guards only; Swift/Rust compilation and device regression still required.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
