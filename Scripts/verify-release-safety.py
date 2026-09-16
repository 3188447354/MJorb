#!/usr/bin/env python3
"""Small source-regression guard. This is NOT compilation or a runtime test."""
from pathlib import Path
import re
import sys
import runpy

HANDOFF_GUARD = runpy.run_path(str(Path(__file__).with_name("verify-certificate-handoff.py")))

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
    rotation = section(portal, "private func rotateCertificatesAndCreateIdentity(", "static func externalSealIdentityFailure(")
    check("revokeCertificate(" in rotation
          and "persistRevokedSigningMaterial(updatedSecret, [candidate.serialNumber])" in rotation
          and "createSigningIdentity(" in rotation,
          "R03: capacity recovery must revoke, persist, then create in one portal transaction")
    create = section(portal, "private func createSigningIdentity(", "private func waitForCreatedCertificate(")
    check("revokeCertificate(" not in create and "cleanUpNewCertificate(" in create,
          "R03: only cleanup of this operation's new certificate is allowed")

    # R04: Apple Portal 的超时必须走 HardTimeout（非结构化任务竞速）。用 withThrowingTaskGroup 时，
    # 任务组退出前必须等所有子任务结束，ALTAppleAPI 回调不返回会让超时错误被无限期拖住
    # —— 等于没有超时，UI 无限等待。此处 2026-09-14 修正过，别再退回去。
    timeout_fn = section(portal, "func withAppleTimeout", "\n}")
    check("HardTimeout.run" in timeout_fn and "withThrowingTaskGroup" not in timeout_fn,
          "R04: withAppleTimeout must use HardTimeout, not withThrowingTaskGroup")

    # R05: Apple 免费账号的请求节流 + 1100 退避重试（2026-09-16）。
    # 抖音这类「主 App + 8 个扩展」的 IPA 需要在 App ID 阶段连续注册 9 个号
    #（每个还要 updateFeatures），再连续申请 9 个描述文件 —— 短时间二十余次连发请求
    # 会触发 Apple 侧掐断会话，返回 1100 "Your session has expired. Please log in."。
    #
    # 判定它是限流而非真过期的依据：用户日志里每一次 AUTH-107 报错前 1–3 秒都有一条
    # 「证书决策」成功。证书申请能成功说明 session 在 Apple 服务端仍然有效，
    # 所以让用户「去重新验证 Apple ID」是死循环（重新登录后密集请求再次触发限流）——
    # 这正是用户反馈的「无论怎样在验证 Apple ID 就报错失效」。
    check("actor AppleRequestThrottle" in portal and "minimumInterval" in portal,
          "R05: Apple requests must be throttled to avoid rate-limit session drops")
    check("await AppleRequestThrottle.shared.wait()" in timeout_fn,
          "R05: every Apple request must pass through the throttle (single entry point)")
    recovery_fn = section(portal, "private func withSessionRecovery", "func sign(")
    check("sessionRecoveryBackoffNanoseconds" in recovery_fn
          and "Self.isSessionExpiredError(error)" in recovery_fn,
          "R05: 1100 must back off and retry instead of failing immediately")
    check("static func isSessionExpiredError" in portal,
          "R05: session expiry classification must stay testable")
    # 逐行检查并跳过注释：文件里刻意留了「为什么不用 contains("1100")」的说明注释，
    # 直接对整段文本做 `not in` 会被自己的注释触发（2026-09-16 实际踩到）。
    substring_matches = [
        line for line in portal.splitlines()
        if 'contains("1100")' in line and not line.strip().startswith("//")
    ]
    check(not substring_matches,
          "R05: 1100 must be matched by error code/message, never by substring")

    # R06: 安装通道的失败熔断 + 批量续签不再前置阻塞（2026-09-16）。
    # 批量续签原先在进入循环前 `await refreshSigningChannel()`，把整段隧道诊断
    #（reset + 18s RSD 握手 + 36×500ms 轮询，硬超时 75s）压在「正在连接设备」上，
    # 这是「点续签后卡很久」的第二个入口。去掉前置等待的前提是通道层有熔断，
    # 否则通道不可用时 N 个 App 会各自重跑一遍 75s 诊断（N×75s）。
    renewal_view_model = load("Seal/Features/Apps/AppsViewModel.swift")
    batch_start = section(renewal_view_model, "private func startBatchRefresh(", "private func runBatchRefresh(")
    check("beginSigningChannel()" in batch_start,
          "R06: batch renewal must warm the channel in parallel")
    check("await self.refreshSigningChannel()" not in batch_start,
          "R06: batch renewal must not block on the tunnel diagnosis up front")
    install_channel_source = load("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift")
    check("failureCooldownSeconds" in install_channel_source
          and "lastFailureAt" in install_channel_source,
          "R06: install channel must fuse repeated tunnel diagnosis failures")
    check("clearFailureCooldown()" in renewal_view_model,
          "R06: user-initiated sessions must clear the fuse")
    # 熔断方法必须留在 protocol 主体里：只写在 extension 的话，`any InstallChannel`
    # 会静态派发到默认空实现，MinimuxerInstallChannel 的覆写永远不会被调用 ——
    # 表现是「用户手动重试也一直被拒」，且守卫全绿（同类坑见 install(onProgress:)）。
    protocol_source = load("Seal/Core/Installation/InstallChannel.swift")
    protocol_body = section(protocol_source, "protocol InstallChannel: Actor {", "\n}")
    check("func clearFailureCooldown() async" in protocol_body,
          "R06: clearFailureCooldown must be a protocol requirement (dynamic dispatch)")

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
    check("if let uuid = metadata.provisioningProfileUUID," in reconcile
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
    # 只校验下载域名不够：同一仓库、同一合法域名下的资产仍可被替换。
    # 必须把「API 元数据声称的版本」与「IPA 内真实版本」交叉校验。
    # 必须查比较逻辑本身：只查「函数存在/被调用」会被 return true 骗过去（变异检查当场抓到）。
    check("Version.compare(advertised, ipaVersion) == .orderedSame" in update_checker
          and "UpdateChecker.advertisedVersion(" in load("Seal/Features/UpdateNoticeView.swift"),
          "Update: the installed IPA version must be cross-checked against the advertised tag")

    # ── 外围专项：通知偏好 ─────────────────────────────────────────────────
    # leadHours 曾是个静默 no-op：getter 恒返回固定值、setter 忽略 newValue，
    # 而 init 还会无条件覆盖已存值 —— 一旦开放配置就会悄悄吞掉写入，且极难排查。
    notif_prefs = load("Seal/Core/Notifications/NotificationPreferences.swift")
    check("defaults.register(defaults:" in notif_prefs
          and "return stored > 0 ? stored : Self.fixedLeadHours" in notif_prefs,
          "Notify: lead time must read what was written and not clobber on init")

    # ── 外围专项：存储路径（符号链接逃逸）─────────────────────────────────
    # standardizedFileURL 只规范化 . / .. ，不解析 symlink：Apps/<uuid> 一旦被换成
    # 指向别处的链接，字符串前缀比较照样通过，写入就落到 Apps 之外。两侧都要解析
    # （iOS 上 Documents 本身就可能位于链接路径下，只解析一侧会得出错误结论）。
    # 明确检查两侧各自都解析：只数总数会被「另一侧还在」掩盖掉单侧退化。
    check("parent.resolvingSymlinksInPath()" in file_store
          and "candidate.resolvingSymlinksInPath()" in file_store,
          "Storage: descendant checks must resolve symlinks on both sides")

    # 证书页必须能回答「这张证书关联了哪些 App」：不能只展示截断 machineName，
    # 也不能只看顶层 serial（扩展 target 可能才有真实序列号）。
    # 「本机已安装 App」清单必须与行标签**同源**（installedAppsAssociated → associatedApps）：
    # 旧实现直接用口径更严的 affectedApps（只看顶层 serial 且要求 state == .installed），
    # 于是同一张证书会出现「行标签说本机已安装 App 在用、下面清单却说暂无」的自相矛盾，
    # Seal 自身（belongsInInstalledList 恒为真）也会被漏掉。撤销影响评估仍必须走 affectedApps。
    cert_impact = load("Seal/Core/Signing/CertificateRevocationImpact.swift")
    cert_view = load("Seal/Features/Settings/SigningCertificateSettingsView.swift")
    check("static func associatedApps(" in cert_impact
          and "app.signingTargets.contains" in cert_impact,
          "Certificates: association lookup must include extension targets")
    check("static func affectedApps(" in cert_impact
          and "static func installedAppsAssociated(" in cert_impact
          and "associatedApps(serialNumber: serialNumber, apps: apps)" in cert_impact,
          "Certificates: the installed-app list must reuse the association rule, not the stricter revocation-impact rule")
    check("installedAppsSection(account: account)" in cert_view
          and "CertificateRevocationImpact.installedAppsAssociated(" in cert_view
          and "本机已安装 App" in cert_view
          and "fullSerialText(certificate.serialNumber)" in cert_view,
          "Certificates: UI must show full identity and associated apps")
    signing_service = load("Seal/Infrastructure/Signing/ApplePortalSigningService.swift")
    check("if team.type == .free, certificates.isEmpty == false" in signing_service
          and 'catch let failure as ImportFailure where failure.code == "SEAL-CERT-204b"' in signing_service
          and "rotationCandidates(" in signing_service,
          "Certificates: unusable/stale bindings must rotate before a free-team request or after exact 3022")
    settings = load("Seal/Features/Settings/SettingsViewModel.swift")
    check("let expirationDate = portalPresence == .invalid" in settings,
          "Certificates: revoked remote certificates must not show stale local expiry")
    check("func importSigningCertificate(from sourceURL: URL" not in settings,
          "Certificates: P12 backup import entry must be removed (one cert per Apple ID)")
    account_secret = load("Seal/Core/Accounts/AccountSecret.swift")
    check("certificateP12BySerial[oldKey] = oldP12" in account_secret,
          "Certificates: creating a new certificate must not discard older local P12 material")
    reuse_section = section(signing_service, "// 根治「创建新证书覆盖旧 P12」的问题", "// 运行包证书只用于安排轮换顺序")
    check("for remote in certificates" in reuse_section
          and "SigningCertificateMaterialPolicy.availableCertificate(secret: secret, serialNumber: remote.serialNumber)" in reuse_section
          and "Self.certificateReusable(local)" in reuse_section,
          "Certificates: signing must reuse any stored P12 whose remote certificate is still active")
    check("isCertificateImporterPresented" not in cert_view
          and "从 P12 备份恢复本机私钥" not in cert_view,
          "Certificates: UI must not expose P12 recovery (removed, one cert per Apple ID)")
    check("revokeCertificate(serialNumber:" in cert_view
          and "nonLocalCertificates" in cert_view
          and "CertificateRevocationImpact.isLocalCertificate(" in cert_view,
          "Certificates: manual revoke must be gated to non-local certificates")

    # Fast IPA 的产物由 build-unsigned-ipa.sh 按版本命名为 Seal_<version>.ipa。
    # 验证/上传若退回旧的 Seal.ipa 固定名，会在编译成功后误报文件不存在。
    ios_fast = load(".github/workflows/ios-fast.yml")
    check("bash Scripts/verify-ipa.sh build/Seal_*.ipa" in ios_fast
          and "build/Seal_*.ipa.sha256" in ios_fast
          and "build/Seal.ipa" not in ios_fast,
          "CI: Fast IPA verification and upload must use the versioned artifact name")

    # ensure-rustbridge 以 xcframework 内的 .source-fingerprint 判定能否复用。
    # 只缓存 target/ 会让每个新 runner 都因指纹缺失而重建并扫描整个静态库。
    rust_cache_inputs = (
        load(".github/workflows/ios.yml"),
        load(".github/workflows/ios-release.yml"),
        ios_fast,
    )
    check(all("Vendor/Minimuxer/RustBridge/lib/RustBridge.xcframework" in workflow
              and "'Vendor/Minimuxer/RustBridge/src/**'" in workflow
              for workflow in rust_cache_inputs),
          "CI: every iOS Rust cache must preserve the matched xcframework and key it by Rust sources")

    # ── 外围专项：供应链（GitHub Action 必须钉到 commit SHA）──────────────
    # actions/cache@v5 这类浮动 major tag 可以被上游移动指向任意代码 ——
    # 只要上游账号或仓库被入侵，CI 就会执行攻击者的代码，并拿到发布用的凭据。
    # 必须钉到 40 位 commit SHA（保留 `# v5` 注释便于人读与 Dependabot 识别）。
    # 注意：@v6.0.2 这种精确到 patch 的标签不在禁止之列（风险远低于 @vN）。
    floating_actions = []
    for name in ("ios.yml", "ios-release.yml", "ios-fast.yml", "pairing-assistant.yml"):
        for line in load(".github/workflows/" + name).splitlines():
            stripped = line.strip()
            if not stripped.startswith("uses:") or "@" not in stripped:
                continue
            ref = stripped.split("@", 1)[1].strip().split()[0]
            if ref.startswith("v") and ref.count(".") == 0:
                floating_actions.append(name + " -> " + stripped)
    check(not floating_actions,
          "Supply chain: GitHub Actions must be pinned to a commit SHA ("
          + " | ".join(floating_actions) + ")")

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

    # 证书页允许手动撤销「非本机在用」证书（真实永久删除），但不提供批量清理入口。
    # 撤销必须被 `nonLocalCertificates` 用 `CertificateRevocationImpact.isLocalCertificate`
    # 挡在本机在用证书之外（误删本机在用证书会让签名身份失效，2026-09-14 真机踩到）。
    ui = load("Seal/Features/Settings/SigningCertificateSettingsView.swift")
    check("prepareCertificateCleanup" not in ui,
          "Copy: certificate page must not expose batch cleanup entry")
    check("nonLocalCertificates(account: account)" in ui
          and "CertificateRevocationImpact.isLocalCertificate(" in ui,
          "Copy: manual revoke must exclude the local in-use certificate")

    # 证书清理（一个 Apple ID 本机只留一张可用证书）：
    # 撤销不可逆，候选判定与执行各有硬约束。
    cleanup_policy = load("Seal/Core/Signing/CertificateCleanupPolicy.swift")
    check("if normalizedLocalUsable.contains(serial)" in cleanup_policy,
          "Cleanup: keyful check must use normalized serial set")
    inspector = load("Seal/Infrastructure/Installation/DeviceProfileInspector.swift")
    check("removeProvisioningProfile" not in inspector,
          "Cleanup: device profile inspection must be read-only")
    check("return parsed > 0 ? serials : nil" in inspector,
          "Cleanup: unparseable dump must mean unverified, not empty")
    settings_vm = load("Seal/Features/Settings/SettingsViewModel.swift")
    cleanup_exec = section(settings_vm, "func executeCertificateCleanup(",
                           "private func persistCreatedCertificate(")
    check("fetchInventory" in cleanup_exec and "freshPlan.revocable.filter" in cleanup_exec,
          "Cleanup: revoke must re-verify against a fresh remote listing")
    check(cleanup_exec.index("createLocalCertificate") > cleanup_exec.index("for certificate in targets"),
          "Cleanup: revoke all before creating the replacement")
    inv = load("Seal/Infrastructure/Signing/ApplePortalInventoryService.swift")
    check("hasLocalPrivateKey: localP12SerialNumbers.contains(" in inv,
          "Cleanup: hasLocalPrivateKey must consider every stored P12, not only the current one")

    # 签名/续签中的孤儿证书自动清理：撤销不可逆，约束必须硬守护。
    coord = load("Seal/Core/Signing/SigningCoordinator.swift")
    check("SEAL-CERT-204a" in coord and "SEAL-CERT-204c" in coord and "SEAL-CERT-204d" in coord,
          "Auto-cleanup: trigger must cover quota, missing-key and stale-binding errors only")
    # 名额满有两条平行归类路径（204a 文案归类 / 204b isCertificateLimitError 归类），
    # 漏挂 204b 会让真机撞上限时无感清理完全不触发（2026-09-14 真机踩到）。
    trigger_fn = section(coord, "static func isOrphanCertificateBlocking", "\n    }")
    check('failure.code == "SEAL-CERT-204b"' in trigger_fn,
          "Auto-cleanup: trigger must also cover SEAL-CERT-204b (isCertificateLimitError path)")
    check("let deviceReferenced = await DeviceProfileInspector.referencedCertificateSerials()" in coord,
          "Auto-cleanup: must consult device profile inspector")
    auto_cleanup = section(coord, "private func autoCleanOrphanCertificatesIfPossible(",
                           "func installSignedArtifact(")
    check("guard let inventory = try? await inventoryService.fetchInventory(" in auto_cleanup,
          "Auto-cleanup: decisions must use a fresh remote listing, never cache")
    check("guard plan.revocable.isEmpty == false else {" in auto_cleanup
          and "guard revokedSerials.isEmpty == false else {" in auto_cleanup,
          "Auto-cleanup: bail out when nothing was or could be revoked")
    cleanup_retry = section(coord,
                            "catch let failure as ImportFailure where Self.isOrphanCertificateBlocking",
                            "account.certificateSerialNumber = portalResult.certificateSerialNumber")
    check("selectedCertificateSerialNumber: nil" in cleanup_retry,
          "Auto-cleanup: retry must drop the revoked binding")

    # Seal 自保护（前置清理绝不碰 Seal 真实签名证书）：
    # 签其他 App 时前置清理如果撤了 Seal 的真实签名证书（比如覆盖安装 keychain 丢私钥后，
    # Seal 正用一张无私钥证书跑着），Seal 下次启动就「不再可用」直接变砖。
    # makePlan 必须只认真实 CMS 签名者（sealActualSignerSerialNumber + identityConfidence），
    # 真实签名者读不出来时整份计划必须 blocked（一张都不撤）。
    check("sealActualSignerSerialNumber" in cleanup_policy
          and "identityConfidence" in cleanup_policy
          and "static func blocked(reason: String)" in cleanup_policy
          and "serial == normalizedSealSigner" in cleanup_policy,
          "Seal self-protection: makePlan must protect the actual CMS signer and block when unknown")
    check("installedIdentity" in auto_cleanup
          and "sealActualSignerSerialNumber: sealActualSigner" in auto_cleanup,
          "Seal self-protection: auto cleanup must pass Seal's actual signer from installedIdentity")

    # Seal 自保护（注册/结算时只能以运行包主程序的真实 CMS 签名者为准）：
    # 描述文件授权证书列表不等于实际签名者；身份读取失败时保留既有记录，
    # 绝不回退到 profile 授权列表（2026-09-15 真机确认误撤会变砖）。
    registrar = load("Seal/Core/Renewal/SelfAppRegistrar.swift")
    check("metadata.installedIdentity?.mainTarget?.signerSerialNumber" in registrar
          and "metadata.certificateSerialNumbers.first" not in registrar,
          "Seal self-protection: registrar must use the actual CMS signer, never the profile-authorized list")
    metadata = load("Seal/Core/Renewal/SelfAppMetadata.swift")
    check("certificateSerialNumbers: profileDetails?.certificateSerialNumbers" in metadata,
          "Seal self-protection: SelfAppMetadata must read certificateSerialNumbers from profile")

    # Seal 自保护（所有证书清理路径都必须只相信真实 CMS 签名者）：
    # 描述文件授权列表可能包含并未实际签名的证书，DB 记录可能是旧值；
    # 两处协调器路径（前置清理 / 一键全撤）与设置页两处路径（分析 / 执行）
    # 都必须从 installedIdentity 读真实签名者，且身份不完整时整体停止。
    check("SelfAppMetadata.current()?.installedIdentity" in coord
          and "runningIdentity?.isComplete == true" in coord,
          "Seal self-protection: coordinator paths must read the actual CMS signer identity")
    check("SelfAppMetadata.current()?.installedIdentity" in settings_vm
          and "runningIdentity?.isComplete == true" in settings_vm,
          "Seal self-protection: settings paths must read the actual CMS signer identity")
    # 一键全撤路径（revokeKeylessCertificatesAfterConfirmation）身份不可读时必须拒绝撤销。
    revoke_keyless = section(coord, "func revokeKeylessCertificatesAfterConfirmation(",
                             "private func autoCleanOrphanCertificatesIfPossible(")
    check("SelfAppMetadata.current()?.installedIdentity" in revoke_keyless
          and "SEAL-CERT-230" in revoke_keyless,
          "Seal self-protection: revoke keyless must stop when the actual signer is unreadable")
    # 危险推断已被根除：描述文件授权列表首项 / 运行包授权集合不得再用于保护决策。
    for path in ("Seal/Core/Signing/SigningCoordinator.swift",
                 "Seal/Features/Settings/SettingsViewModel.swift",
                 "Seal/Infrastructure/Signing/ApplePortalSigningService.swift"):
        text = load(path)
        check("SelfAppMetadata.current()?.certificateSerialNumbers.first" not in text
              and "runningSealSerials" not in text,
              f"Seal self-protection: profile-based signer inference must be gone in {path}")
    # 接管决策：空槽位直接建、满槽位只能请求撤销非 A 候选、签名者未知一律阻断。
    takeover = load("Seal/Core/Signing/CertificateTakeoverPolicy.swift")
    check("case reuseLocal(serialNumber: String)" in takeover
          and "case createLocal" in takeover
          and "case requestRevocation(candidateSerialNumbers: [String])" in takeover
          and "case blocked(reason: String)" in takeover
          and "guard identityComplete," in takeover
          and "remoteSerialNumbers.filter { normalize($0) != protected }" in takeover,
          "Takeover: decision policy must cover reuse/create/requestRevocation/blocked and never offer A")
    # 手动撤销（证书页逐张撤销）必须先挡住真实签名者 A；身份不可读时拒绝一切撤销。
    check("CertificateRevocationImpact.isActualSealSigner(" in settings_vm
          and "SEAL-CERT-230a" in settings_vm,
          "Seal self-protection: manual revoke must refuse the actual Seal signer")

    # 自续签事务化结构断言：旧 handoff 模式必须绝迹，单次提交与真实身份读取必须在场。
    forbidden_patterns = {
        "Seal/Core/Signing/SigningCoordinator.swift": [
            "for attempt in 1...2",
            "recoverPendingSelfReplacement",
        ],
        "Seal/Core/Renewal/SelfAppRegistrar.swift": [
            "pendingSelfReplacementRecovery",
            "claimAutomaticRecovery",
        ],
    }
    for path, patterns in forbidden_patterns.items():
        text = load(path)
        for pattern in patterns:
            check(pattern not in text,
                  f"Transaction: forbidden legacy pattern '{pattern}' must be gone in {path}")
    required_patterns = {
        "Seal/Core/Renewal/SelfReplacementTransactionStore.swift": [
            "claimSubmission",
            "alreadySubmitted",
        ],
        "Seal/Infrastructure/Renewal/AppBundleSigningIdentityReader.swift": [
            "checkMachOCodeSignatures",
            "signerNotAuthorizedByProfile",
        ],
    }
    for path, patterns in required_patterns.items():
        text = load(path)
        for pattern in patterns:
            check(pattern in text,
                  f"Transaction: required pattern '{pattern}' missing in {path}")

    # 一键确认盘活（SEAL-CERT-204e）：在用的无钥匙证书绝不静默撤，必须经失败页确认。
    check("if case .blockedByInUseKeylessCerts" in cleanup_retry,
          "204e must surface when keyless certificates are still in use")
    # Seal 自身续签绝不撤自己的证书（会立刻打不开，2026-09-14 真机踩到）。两道护栏：
    # ① 命中「在用的无钥匙证书」时不抛 204e，回退原错误；② 一键全撤跳过 Seal 在用的证书。
    check("if app.isSeal {" in cleanup_retry,
          "Seal self-renewal must never surface 204e (revoke makes Seal unlaunchable)")
    check("sealProtectedSerials" in coord and "sealProtectedSerials.contains" in coord,
          "Sacrifice: one-tap full revoke must skip Seal's own in-use certificate")
    check("func revokeKeylessCertificatesAfterConfirmation(" in coord,
          "Sacrifice: coordinator must expose the confirmation-gated revoke entry")
    check("SEAL-CERT-204e" in coord and "SEAL-CERT-204f" in coord,
          "Sacrifice: error codes 204e/204f must stay unique and present")
    check("CertificateCleanupPolicy.sacrificeCandidates(" in coord,
          "Sacrifice: candidates must come from the shared policy")
    apps_vm = load("Seal/Features/Apps/AppsViewModel.swift")
    check("func confirmCertificateSacrificeAndRetry()" in apps_vm
          and 'failure.code == "SEAL-CERT-204e"' in apps_vm,
          "Sacrifice: ViewModel one-tap entry must be gated on the 204e failure")
    check("resignAppsAffectedByCertificateSacrificeIfNeeded(signingSucceeded: signingSucceeded)" in apps_vm,
          "Sacrifice: affected installed apps must be re-signed after the retry succeeds")
    progress_view = load("Seal/Features/Apps/SigningProgressView.swift")
    check('"撤销并继续签名"' in progress_view
          and "viewModel.confirmCertificateSacrificeAndRetry()" in progress_view,
          "Sacrifice: failure page must wire the one-tap button to the ViewModel")

    # 证书回收已收敛为无感自动清理 + 204e 一键确认；证书页只读，不再提供手动撤销入口。
    # 任何 recovery 文案都不许再引导用户「去撤销证书」（那是死链接），唯一允许保留的
    # 「撤销」措辞是 204e 失败页的「撤销并继续签名」（有真实按钮，见 SigningProgressView）。
    manual_revoke_copy = []
    for path in ("Seal/Core/Signing/SigningCoordinator.swift",
                 "Seal/Infrastructure/Signing/ApplePortalCertificateService.swift",
                 "Seal/Infrastructure/Signing/ApplePortalSigningService.swift"):
        for line in load(path).splitlines():
            if "recovery:" in line and "撤销" in line and "撤销并继续签名" not in line:
                manual_revoke_copy.append(path + " -> " + line.strip())
    check(not manual_revoke_copy,
          "Copy: recovery must not instruct manual certificate revocation ("
          + " | ".join(manual_revoke_copy) + ")")

    versions = re.findall(r"MARKETING_VERSION:\s*(\S+)", load("project.yml"))
    check(len(versions) == 1,
          "Release: Seal must declare a single MARKETING_VERSION (no extension target)")
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
    handoff_failures = HANDOFF_GUARD["violations"](load)
    checks += 6
    failures.extend(handoff_failures)
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
         "            try await persistRevokedSigningMaterial(updatedSecret, [candidate.serialNumber])\n            await diagnostic(\"证书轮换：已撤销",
         "            // revoked state persistence removed\n            await diagnostic(\"证书轮换：已撤销", "R03:"),
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
         'recovery: "请在「我的」中重新同步证书状态后重试"',
         'recovery: "在「我的」页面撤销一个旧签名证书后重试"',
         "Copy: recovery must not instruct manual certificate revocation"),
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
         "// 后者是 R07：同版本续签会换掉 profile 但版本号不变，只比版本就会漏掉结算。\n            try await reconcileSealRecordFromRunningBundleIfNeeded(",
         "// 后者是 R07\n            try await cleanupDuplicateSealRecords(",
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
        ("Seal/Infrastructure/UpdateChecker.swift",
         "Version.compare(advertised, ipaVersion) == .orderedSame",
         "true",
         "Update: the installed IPA version must be cross-checked"),
        ("Seal/Core/Notifications/NotificationPreferences.swift",
         "return stored > 0 ? stored : Self.fixedLeadHours",
         "return Self.fixedLeadHours",
         "Notify: lead time must read what was written"),
        ("Seal/Infrastructure/Storage/AppFileStore.swift",
         "candidate.resolvingSymlinksInPath().standardizedFileURL.path",
         "candidate.standardizedFileURL.path",
         "Storage: descendant checks must resolve symlinks"),
        ("Seal/Core/Signing/CertificateRevocationImpact.swift",
         "return app.signingTargets.contains { signingTarget in",
         "return false // extension association removed",
         "Certificates: association lookup must include extension targets"),
        ("Seal/Features/Settings/SigningCertificateSettingsView.swift",
         "CertificateRevocationImpact.installedAppsAssociated(",
         "CertificateRevocationImpact.installedAppsAssociatedUnused(",
         "Certificates: UI must show full identity and associated apps"),
        ("Seal/Core/Signing/CertificateRevocationImpact.swift",
         "associatedApps(serialNumber: serialNumber, apps: apps)",
         "apps.filter { _ in false }",
         "Certificates: the installed-app list must reuse the association rule"),
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "if team.type == .free, certificates.isEmpty == false {",
         "if false {",
         "Certificates: unusable/stale bindings must rotate before a free-team request or after exact 3022"),
        ("Seal/Features/Settings/SettingsViewModel.swift",
         "let expirationDate = portalPresence == .invalid",
         "let expirationDate = false",
         "Certificates: revoked remote certificates must not show stale local expiry"),
        ("Seal/Features/Settings/SigningCertificateSettingsView.swift",
         "CertificateRevocationImpact.isLocalCertificate(",
         "true // ",
         "Copy: manual revoke must exclude the local in-use certificate"),
        ("Seal/Core/Accounts/AccountSecret.swift",
         "certificateP12BySerial[oldKey] = oldP12",
         "certificateP12BySerial.removeValue(forKey: oldKey)",
         "Certificates: creating a new certificate must not discard older local P12 material"),
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "for remote in certificates {\n            guard let local = SigningCertificateMaterialPolicy.availableCertificate(secret: secret, serialNumber: remote.serialNumber),\n                  Self.certificateReusable(local) else { continue }",
         "if false {",
         "Certificates: signing must reuse any stored P12 whose remote certificate is still active"),
        (".github/workflows/ios.yml",
         "uses: actions/cache@caa296126883cff596d87d8935842f9db880ef25 # v5",
         "uses: actions/cache@v5",
         "Supply chain: GitHub Actions must be pinned"),
        ("Seal/Core/Signing/CertificateCleanupPolicy.swift",
         "if normalizedLocalUsable.contains(serial)",
         "if localUsableSerials.contains(serial) // ",
         "Cleanup: keyful check must use normalized serial set"),
        ("Seal/Infrastructure/Installation/DeviceProfileInspector.swift",
         "return parsed > 0 ? serials : nil",
         "return serials",
         "Cleanup: unparseable dump"),
        ("Seal/Features/Settings/SettingsViewModel.swift",
         "let targets = freshPlan.revocable.filter {",
         "let targets = plan.revocable.filter {",
         "Cleanup: revoke must re-verify"),
        ("Seal/Infrastructure/Signing/ApplePortalInventoryService.swift",
         "hasLocalPrivateKey: localP12SerialNumbers.contains(",
         "hasLocalPrivateKey: false // ",
         "Cleanup: hasLocalPrivateKey"),
        ("Seal/Core/Signing/SigningCoordinator.swift",
         "let deviceReferenced = await DeviceProfileInspector.referencedCertificateSerials()",
         "let deviceReferenced: Set<String>? = nil // ",
         "Auto-cleanup: must consult device profile inspector"),
        ("Seal/Core/Signing/SigningCoordinator.swift",
         "                    selectedCertificateSerialNumber: nil,\n                    allowDroppingExtensions: allowDroppingExtensions,",
         "                    selectedCertificateSerialNumber: effectiveCertificateSerialNumber,\n                    allowDroppingExtensions: allowDroppingExtensions,",
         "Auto-cleanup: retry must drop the revoked binding"),
        ("Seal/Core/Signing/SigningCoordinator.swift",
         "if case .blockedByInUseKeylessCerts(let appNames, let deviceOnlyCount) = cleanupOutcome {",
         "if false { // blocked in-use keyless certs no longer surface 204e ",
         "204e must surface when keyless certificates are still in use"),
        ("Seal/Features/Apps/AppsViewModel.swift",
         "resignAppsAffectedByCertificateSacrificeIfNeeded(signingSucceeded: signingSucceeded)",
         "// affected apps left dead after certificate sacrifice",
         "Sacrifice: affected installed apps must be re-signed after the retry succeeds"),
    ]
    mutations += [
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "CertificateRequestFailurePolicy.requestFailure", "LegacyCertificateFailure.requestFailure",
         "both certificate creation paths must use the shared error policy"),
        ("Seal/Core/Signing/SigningCoordinator.swift",
         "selfReplacement.prepare(", "selfReplacement.skippedPrepare(",
         "a self replacement transaction must persist"),
        ("Seal/Features/Settings/SettingsViewModel.swift",
         "preservingSigningMaterial(from:", "discardingSigningMaterial(from:",
         "reauthentication must retain historical P12 material"),
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "    await AppleRequestThrottle.shared.wait()\n", "",
         "R05: every Apple request must pass through the throttle"),
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "guard Self.isSessionExpiredError(error) else { throw error }",
         "guard false else { throw error }",
         "R05: 1100 must back off and retry"),
        ("Seal/Features/Apps/AppsViewModel.swift",
         "            await self.installChannel?.clearFailureCooldown()\n            self.beginSigningChannel()\n            await self.runBatchRefresh(appIDs: appIDs)",
         "            guard await self.refreshSigningChannel() else { return }\n            await self.runBatchRefresh(appIDs: appIDs)",
         "R06: batch renewal must not block"),
        ("Seal/Core/Installation/InstallChannel.swift",
         "    func clearFailureCooldown() async\n    func pushIpa",
         "    func pushIpa",
         "R06: clearFailureCooldown must be a protocol requirement"),
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
