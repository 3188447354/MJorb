#!/usr/bin/env python3
"""Small source-regression guard. This is NOT compilation or a runtime test."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]

def read(path):
    return (ROOT / path).read_text(encoding="utf-8-sig")

def section(text, start, end):
    # 标记找不到时必须报错，不能静默退化成「返回整段」—— 那会让守卫悄悄失去约束力，
    # 而且表现是「检查全绿」，比直接失败危险得多（2026-09-14 真实踩到一次）。
    if start not in text:
        raise AssertionError("section start marker not found: " + start)
    tail = text.split(start, 1)[1]
    if end not in tail:
        raise AssertionError("section end marker not found after " + start + ": " + end)
    return tail.split(end, 1)[0]

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

    # R04: Apple Portal 的超时必须走 HardTimeout（非结构化任务竞速）。用 withThrowingTaskGroup 时，
    # 任务组退出前必须等所有子任务结束，ALTAppleAPI 回调不返回会让超时错误被无限期拖住
    # —— 等于没有超时，UI 无限等待。此处 2026-09-14 修正过，别再退回去。
    timeout_fn = section(portal, "func withAppleTimeout", "\n}")
    check("HardTimeout.run" in timeout_fn and "withThrowingTaskGroup" not in timeout_fn,
          "R04: withAppleTimeout must use HardTimeout, not withThrowingTaskGroup")

    # R04: Portal 三个服务的回调一律经 ContinuationBox 转发。裸 continuation 第二次 resume
    # 不是可捕获错误，而是 SWIFT TASK CONTINUATION MISUSE 致命崩溃（进程直接终止）。
    # AltSign 存在两条重复回调路径：「先报错、随后迟到地报成功」与「超时先到、回调才到」。
    # 2026-09-14 统一加固，22 个回调创建点全部套盒。
    box_source = load("Seal/Core/Concurrency/ContinuationBox.swift")
    check("final class ContinuationBox" in box_source and "continuation = nil" in box_source,
          "R04: ContinuationBox must clear the stored continuation on first resume")
    portal_services = ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
                       "Seal/Infrastructure/Signing/ApplePortalCertificateService.swift",
                       "Seal/Infrastructure/Signing/ApplePortalInventoryService.swift")
    raw_resume = []
    for path in portal_services:
        for line in load(path).splitlines():
            stripped = line.strip()
            if stripped.startswith("//"):
                continue
            if "Self.resume(continuation," in stripped or "continuation.resume(" in stripped:
                raw_resume.append(path + " -> " + stripped)
    check(not raw_resume,
          "R04: Portal callbacks must go through ContinuationBox (" + " | ".join(raw_resume) + ")")
    for path in portal_services:
        created = load(path).count("withCheckedThrowingContinuation")
        boxed = load(path).count("let callback = ContinuationBox(continuation)")
        check(created == boxed and created > 0,
              "R04: every continuation in " + path + " needs a ContinuationBox")

    # R04: 写 API（创建证书）超时 ≠ 失败。服务端可能已创建但响应丢失，而私钥由 AltSign 本地
    # 生成、只随响应返回 —— 响应一丢就不可恢复。必须对账后如实报告：绝不盲目重试（多占名额）、
    # 绝不自动撤销（可能撤掉正要用的证书），且「无法确认」不能当成「没有创建」。
    add_cert = section(portal, "private func addCertificate(", "enum OrphanReconciliation")
    check("isTimeoutError" in add_cert and "reconcileCertificateCreation" in add_cert,
          "R04: certificate creation timeout must reconcile instead of blindly retrying")
    check("case inconclusive" in portal and "case found(serialNumber:" in portal,
          "R04: reconciliation must distinguish unknown from not-created")

    # 日志脱敏：导出/上报的日志会离开设备。以下四类形态旧实现全都盖不住，属于真实明文外泄，
    # 2026-09-14 补齐。改脱敏器时别把这四条规则删掉或写窄。
    redactor = load("Seal/Infrastructure/Diagnostics/LogPrivacyRedactor.swift")
    check("redacted = redactPEMBlocks(in: redacted)" in redactor
          and "BEGIN [A-Z0-9 ]*PRIVATE KEY" in redactor,
          "Log: PEM private key blocks must be redacted as a whole")
    check("redacted = redactAuthorizationSchemes(in: redacted)" in redactor
          and "Bearer|Basic|Token|Digest" in redactor,
          "Log: credentials following an auth scheme word must be redacted")
    check('\\b"?\\s*[：:=]' in redactor,
          "Log: JSON keys are quoted, so an optional closing quote before the separator is required")

    # G（R10/R11）：缺账号不能静默省略。旧实现 `guard let accountID else { return nil }`
    # 会让「批量续签完成」掩盖「有应用根本没被处理」——用户既看不到它也不知道为什么。
    planner = load("Seal/Core/Renewal/RefreshPlanner.swift")
    planner_code = "\n".join(
        line for line in planner.splitlines() if line.strip().startswith("//") is False
    )
    check("return nil" not in planner_code,
          "G: planner must not silently drop apps without an account")
    check("state: .requiresAction" in planner and "missingAccountReason" in planner,
          "G: apps without an account must enter the queue as requiresAction with a reason")
    store = load("Seal/Infrastructure/Renewal/RefreshQueueStore.swift")
    check("func recoverInterrupted()" in store
          and "state == .running" in store
          and "state = .unknown" in store,
          "G: launch recovery must downgrade interrupted running items to unknown")
    check("func outstanding()" in store,
          "G: outstanding() is required so recovery never redoes completed work")
    coordinator = load("Seal/Core/Renewal/RenewalCoordinator.swift")
    check("needsAction: needsAction" in coordinator and "isBalanced" in coordinator,
          "G: batch result must count needsAction separately and expose the balance invariant")
    check("item.isExecutable" in coordinator,
          "G: requiresAction items must be counted and shown, not silently skipped")

    # F（R09）：三条安装入口必须共用同一份校验，且必须覆盖**每一个** target。
    # 只查主 target 会放过「主 profile 有效、扩展 profile 已过期」的包 ——
    # 它一路走到设备端，只换来一个 ApplicationVerificationFailed 之类的模糊错误。
    pre_install = load("Seal/Core/Signing/PreInstallValidation.swift")
    check("guard target.profileExpirationDate > now else" in pre_install
          and "for target in targets" in pre_install,
          "F: pre-install validation must check every target, not just the main one")
    check("Set(target.certificateSerialNumbers.map(" in pre_install
          and "SigningCertificateSelectionPolicy.normalizedSerialNumber" in pre_install,
          "F: certificate serial comparison must be normalized across sources")
    signing_coord = load("Seal/Core/Signing/SigningCoordinator.swift")
    check(signing_coord.count("PreInstallValidation.validate(") == 2,
          "F: both install entries must route through PreInstallValidation")

    # ── C 包（R06 检查 / 维护互斥）──────────────────────────────────────────
    # 读取路径必须是只读的：记录恢复、Seal 自注册、孤儿文件清理曾挂在 load() 里，
    # 于是「看列表」这种纯读取动作会顺手改 DB 和删文件，并与用户操作交错。
    apps_view = load("Seal/Features/Apps/AppsViewModel.swift")
    load_body = section(apps_view, "func load(force: Bool = false) async {", "func isCurrentLoad(")
    check("restoreMissingRecords" not in load_body
          and "clearOrphanedAppFiles" not in load_body
          and "ensureRegistered" not in load_body,
          "C: the app-list read path must not write records or delete files")
    check(load_body.count("await self.isCurrentLoad(generation)") >= 3,
          "C: every background write-back must be guarded by the load generation")

    job = load("Seal/Core/Maintenance/AppMaintenanceJob.swift")
    check("guard gate.shouldAbort(token) == false else" in job,
          "C: the sweep must re-check the lease before deleting anything")
    check(job.count("gate.shouldAbort(token)") >= 3,
          "C: every maintenance stage must have an abort checkpoint")
    check("fetchAll()" in section(job, "3. 孤儿文件清理", "private static func unexpectedFailure"),
          "C: valid app ids must be re-read from the DB right before deleting")

    file_store = load("Seal/Infrastructure/Storage/AppFileStore.swift")
    sweep = section(file_store, "func clearOrphanedAppFiles(", "private static func transactionID(")
    check("liveTransactionIDs.contains(transactionID)" in sweep,
          "C: in-flight import transaction directories must never be swept")
    check("now.timeIntervalSince(modifiedAt) < minimumAge" in sweep,
          "C: freshly created directories need a grace period")

    gate = load("Seal/Core/Maintenance/MaintenanceGate.swift")
    check("beginWaiting" not in gate,
          "C: maintenance must never wait on a foreground lease")

    root_view = load("Seal/Features/Apps/AppsRootView.swift")
    maintenance_at = root_view.find("runMaintenanceIfIdle()")
    first_load_at = root_view.find("await viewModel.load()")
    check(maintenance_at != -1 and first_load_at != -1 and maintenance_at < first_load_at,
          "C: maintenance must run before the first read so recovered records are visible")

    # ── D 包（R07 自续签确认）──────────────────────────────────────────────
    # 同版本续签会换掉 profile（新 UUID、新有效期）但版本号不变 ⇒ 结算必须按 profile 身份，
    # 只比版本号会把「那次自更新其实失败了」当成成功，UI 显示一个设备上不存在的有效期。
    self_metadata = load("Seal/Core/Renewal/SelfAppMetadata.swift")
    check("provisioningProfileUUID" in self_metadata
          and "ProvisioningProfileReader().details(from:" in self_metadata,
          "D: the running bundle must expose its provisioning profile identity")
    self_registrar = load("Seal/Core/Renewal/SelfAppRegistrar.swift")
    check("reconcileSealRecordFromRunningBundleIfNeeded" in self_registrar
          and "reconcileSealRecordBindingIfNeeded" not in self_registrar,
          "D: the same-version branch must settle from the running bundle")
    same_version = section(self_registrar, "// 版本一致且文件存在", "// 版本变更或文件缺失")
    check("reconcileSealRecordFromRunningBundleIfNeeded" in same_version,
          "D: the same-version branch must reconcile from the running bundle")
    reconcile = section(
        self_registrar,
        "private func reconcileSealRecordFromRunningBundleIfNeeded(",
        "try await appStore.save(updated)"
    )
    check("metadata.provisioningProfileUUID" in reconcile
          and "metadata.expirationDate" in reconcile,
          "D: settlement must compare profile identity and expiry")

    # G 的 BatchRefreshResult 把 remaining 改成了计算属性，构造点必须改用 needsAction。
    # 漏改一个构造点就是编译错误（2026-09-14 真的漏了一处，CI build-package 挂掉）。
    restored_call = section(apps_view, "restored.status = .completed(.init(", ")")
    check("needsAction:" in restored_call and "remaining:" not in restored_call,
          "G: every BatchRefreshResult construction site must fill needsAction")

    # ── E 包（R08：签名产物 vs 已安装快照）──────────────────────────────────
    # UI 到期日取 `provisioningProfileExpirationDate ?? expiryDate`。签名阶段就推进顶层
    # profile 字段，安装失败/进程被杀时界面会显示设备上并不存在的日期 —— 用户以为续签成功，
    # 直到应用被吊销才发现。顶层字段必须只描述设备上正在运行的那份构建。
    apply_result = section(
        signing_coord,
        "private func applySigningResult(",
        "app.entitlementValidationStatus"
    )
    check("if advancesInstalledSnapshot {" in apply_result,
          "E: top-level profile fields must not advance before install verification")
    snapshot = load("Seal/Core/Signing/SignedArtifactSnapshot.swift")
    check("static func statusAfterSigning(" in snapshot
          and "static func advanceInstalled(" in snapshot
          and "awaitingVerification" in snapshot,
          "E: signed artifact and installed snapshot must be separated")
    # 必须排除被注释掉的调用：单纯 `in` 匹配会把 `// SignedArtifactSnapshot.advanceInstalled(`
    # 也算进去（守卫自己的变异检查抓到了这一点）。
    advance_lines = [
        line for line in signing_coord.splitlines()
        if "SignedArtifactSnapshot.advanceInstalled(" in line
        and line.strip().startswith("//") == False
    ]
    check(len(advance_lines) >= 1,
          "E: the install-verified path must advance the snapshot")

    # ── B 包（R05 安装单飞：超时不得重试）──────────────────────────────────
    # 安装 FFI 是同步阻塞、无法取消：超时只代表上层不再等待，底下那次安装很可能还在跑。
    # 重试就会在同一个 Bundle ID 上出现两个并发 installd —— 即「第二次安装」。
    install_channel = load("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift")
    check(install_channel.count("if Self.isTimeoutInstallError(error) {") == 2,
          "B: both install retry loops must treat timeout as terminal")
    check("error is HardTimeout.TimeoutError" in install_channel,
          "B: timeout detection must not depend on error text")

    # ── B 包（R05 · Rust 侧：RSD 创建 single-flight）───────────────────────
    # create_rppairing_rsd_connection() 是 async 的，创建期间标准库 Mutex 的锁已释放；
    # 没有门禁时两个并发调用会各自建一条隧道，后者覆盖前者 → 泄漏连接 + 设备端 RSD 状态混乱。
    rsd = load("Vendor/Minimuxer/RustBridge/src/idevice_support/rsd.rs")
    check("static RSD_CREATION_GATE: OnceLock<tokio::sync::Mutex<()>>" in rsd
          and "async fn ensure_cached_rsd_connection(" in rsd,
          "B: RSD creation must be single-flight behind a creation gate")
    # 光有门禁不够：拿到门禁后必须再看一次缓存，否则只是把「两个并发创建」
    # 变成「两个顺序创建」，照样泄漏一条。用「创建调用只应有一处」来锁住这点。
    check(rsd.count("create_rppairing_rsd_connection().await?") == 1,
          "B: RSD creation must happen in exactly one place (inside the gate)")

    # ── 外围专项：更新真实性 ───────────────────────────────────────────────
    # 应用内更新是一条远程代码投递通道。browser_download_url 是不可信输入：
    # 不校验 host 就等于允许从任意域名拉 IPA；取「第一个 .ipa」则让多附件 Release
    # 的装载结果取决于 API 返回顺序 —— 「往 Release 多加一个附件」就成了投毒手法。
    update_checker = load("Seal/Infrastructure/UpdateChecker.swift")
    check("static func isTrustedDownloadURL(" in update_checker
          and "hasSuffix(\".githubusercontent.com\")" in update_checker,
          "Update: asset URLs must be pinned to GitHub over HTTPS")
    check("guard candidates.count == 1 else { return nil }" in update_checker,
          "Update: an ambiguous set of IPA assets must not yield a direct link")

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
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "return try await HardTimeout.run(seconds: TimeInterval(seconds), operation)",
         "return try await withThrowingTaskGroup(of: T.self) { group in try await group.next()! }",
         "R04: withAppleTimeout must use HardTimeout"),
        ("Seal/Infrastructure/Signing/ApplePortalInventoryService.swift",
         "callback.resume(returning: LegacyBox(teams))",
         "continuation.resume(returning: LegacyBox(teams))",
         "R04: Portal callbacks must go through ContinuationBox"),
        ("Seal/Infrastructure/Signing/ApplePortalInventoryService.swift",
         "let callback = ContinuationBox(continuation)",
         "let callback = (continuation)",
         "R04: every continuation in"),
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "guard Self.isTimeoutError(error) else { throw error }",
         "guard false else { throw error }",
         "R04: certificate creation timeout"),
        ("Seal/Infrastructure/Diagnostics/LogPrivacyRedactor.swift",
         "redacted = redactPEMBlocks(in: redacted)",
         "",
         "Log: PEM private key blocks"),
        ("Seal/Core/Renewal/RefreshPlanner.swift",
         "state: .requiresAction,",
         "state: .pending,",
         "G: apps without an account must enter the queue"),
        ("Seal/Infrastructure/Renewal/RefreshQueueStore.swift",
         "items[index].state = .unknown",
         "items[index].state = .completed",
         "G: launch recovery must downgrade"),
        ("Seal/Core/Signing/PreInstallValidation.swift",
         "guard target.profileExpirationDate > now else",
         "guard true else",
         "F: pre-install validation must check every target"),
        ("Seal/Core/Signing/PreInstallValidation.swift",
         "Set(target.certificateSerialNumbers.map(",
         "Set(target.certificateSerialNumbers",
         "F: certificate serial comparison"),
        ("Seal/Core/Signing/SigningCoordinator.swift",
         "if case .rejected = PreInstallValidation.validate(",
         "if false {",
         "F: both install entries"),
        ("Seal/Infrastructure/Signing/ApplePortalCertificateService.swift",
         'recovery: "在「我的」→「签名证书」中撤销一个旧签名证书后重试"',
         'recovery: "在「我的」页面撤销一个旧签名证书后重试"',
         "Copy: revoke guidance"),
        ("Seal/Core/Maintenance/AppMaintenanceJob.swift",
         "guard gate.shouldAbort(token) == false else",
         "guard true else",
         "C: the sweep must re-check the lease"),
        ("Seal/Infrastructure/Storage/AppFileStore.swift",
         "liveTransactionIDs.contains(transactionID)",
         "false",
         "C: in-flight import transaction directories"),
        ("Seal/Infrastructure/Storage/AppFileStore.swift",
         "now.timeIntervalSince(modifiedAt) < minimumAge",
         "false",
         "C: freshly created directories need a grace period"),
        ("Seal/Features/Apps/AppsViewModel.swift",
         "await self.isCurrentLoad(generation)",
         "true",
         "C: every background write-back must be guarded"),
        ("Seal/Features/Apps/AppsRootView.swift",
         "await viewModel.runMaintenanceIfIdle()",
         "",
         "C: maintenance must run before the first read"),
        ("Seal/Core/Renewal/SelfAppMetadata.swift",
         "ProvisioningProfileReader().details(from:",
         "ProvisioningProfileReader().summary(from:",
         "D: the running bundle must expose its provisioning profile identity"),
        ("Seal/Core/Renewal/SelfAppRegistrar.swift",
         "try await reconcileSealRecordFromRunningBundleIfNeeded(",
         "try await cleanupDuplicateSealRecords(records: records, keepID: existing.id) // ",
         "D: the same-version branch must reconcile"),
        ("Seal/Core/Renewal/SelfAppRegistrar.swift",
         "if let uuid = metadata.provisioningProfileUUID,",
         "if let uuid = existing.provisioningProfileUUID,",
         "D: settlement must compare profile identity and expiry"),
        ("Seal/Features/Apps/AppsViewModel.swift",
         "needsAction: max(0, total - succeeded - failed)",
         "remaining: max(0, total - succeeded - failed)",
         "G: every BatchRefreshResult construction site"),
        ("Seal/Core/Signing/SigningCoordinator.swift",
         "if advancesInstalledSnapshot {",
         "if true {",
         "E: top-level profile fields must not advance"),
        ("Seal/Core/Signing/SignedArtifactSnapshot.swift",
         "return isSeal ? .installed : .awaitingVerification",
         "return .installed",
         "E: signed artifact and installed snapshot must be separated"),
        ("Seal/Core/Signing/SigningCoordinator.swift",
         "SignedArtifactSnapshot.advanceInstalled(",
         "// SignedArtifactSnapshot.advanceInstalled(",
         "E: the install-verified path must advance the snapshot"),
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "if Self.isTimeoutInstallError(error) {",
         "if false {",
         "B: both install retry loops must treat timeout as terminal"),
        ("Vendor/Minimuxer/RustBridge/src/idevice_support/rsd.rs",
         "ensure_cached_rsd_connection().await?;",
         "create_rppairing_rsd_connection().await?;",
         "B: RSD creation must happen in exactly one place"),
        ("Seal/Infrastructure/UpdateChecker.swift",
         "guard candidates.count == 1 else { return nil }",
         "guard candidates.isEmpty == false else { return nil }",
         "Update: an ambiguous set of IPA assets"),
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
