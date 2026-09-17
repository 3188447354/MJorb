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

def squash(text):
    """把连续空白（含换行与缩进）压成单个空格。

    多行代码的断言写成 `"case .inactive: return .waitForForeground"` 这种一行式，
    比在守卫里拼换行符 + 数缩进空格可靠得多 —— 缩进一改守卫就会莫名其妙地红。
    """
    return " ".join(text.split())

def strip_comments(text):
    """去掉 // 与 /* */ 注释，保留字符串字面量原样（字符串里的 // 不是注释）。"""
    out = []
    i = 0
    in_string = False
    while i < len(text):
        ch = text[i]
        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < len(text):
                out.append(text[i + 1])
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and i + 1 < len(text) and text[i + 1] == "/":
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        if ch == "/" and i + 1 < len(text) and text[i + 1] == "*":
            i += 2
            while i + 1 < len(text) and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)

_SIMULATOR_POSITIVE = re.compile(r"^targetEnvironment\s*\(\s*simulator\s*\)$")
_SIMULATOR_NEGATIVE = re.compile(r"^!\s*targetEnvironment\s*\(\s*simulator\s*\)$")

def simulator_activity(condition):
    """该条件在**模拟器切片**下的真假；不认识的写法返回 None（= 两片都算编译）。

    只认识 `targetEnvironment(simulator)` 这一种条件，是刻意的：`#if DEBUG`、
    `#if os(iOS)` 之类的取值不取决于目标平台，把它们当成「两片都编译」既不会漏掉
    真正的问题，也不会制造误报。
    """
    condition = condition.strip()
    if _SIMULATOR_POSITIVE.match(condition):
        return True
    if _SIMULATOR_NEGATIVE.match(condition):
        return False
    return None

def mask_inactive_on_simulator(text):
    """把「模拟器切片不编译」的行抹成等长空白，返回 (抹后文本, 被抹掉的行号集合)。

    为什么要连 `#if targetEnvironment(simulator)` 的 `#else` 分支一起抹掉：那段同样
    不在模拟器上编译。第一版只认 `!targetEnvironment(simulator)`，于是
    `bindTunnelConfiguration()`（定义在 `#if !simulator` 里、调用点却在
    `#if simulator` 的 `#else` 里）被误报成「模拟器缺符号」—— 两处都是设备专属，
    根本没有问题。误报比漏报更坏：它会逼着后来的人把守卫删掉。
    """
    out = list(text)
    frames = []
    blanked = set()
    offset = 0
    for index, line in enumerate(text.splitlines(keepends=True), start=1):
        stripped = line.strip()
        if stripped.startswith("#"):
            head = stripped.split(None, 1)[0]
            if head == "#if":
                frames.append(simulator_activity(stripped[3:]))
            elif head == "#elseif" and frames:
                frames[-1] = simulator_activity(stripped[len("#elseif"):])
            elif head == "#else" and frames:
                frames[-1] = None if frames[-1] is None else (not frames[-1])
            elif head == "#endif" and frames:
                frames.pop()
        if any(frame is False for frame in frames):
            blanked.add(index)
            for k in range(offset, offset + len(line)):
                if out[k] != "\n":
                    out[k] = " "
        offset += len(line)
    return "".join(out), blanked

# 只匹配**缩进恰好 4 空格**的声明，即顶层类型的成员。函数体内的局部变量缩进更深，
# 必须排除：`let ipaMB` / `let detail` 这类名字在设备专属分支与模拟器分支里各有一份，
# 按「名字出现在抹后文本里」判定会把它们全部误报成缺符号。
_SIMULATOR_MEMBER = re.compile(
    r"^    (?:@\w+[^\n]*\n    )*"
    r"(?:private\s+|fileprivate\s+|internal\s+|public\s+|open\s+)?"
    r"(?:static\s+)?(?:func|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)",
    re.M,
)

def match_paren(text, open_index):
    """返回与 text[open_index] == '(' 配对的 ')' 下标；找不到返回 -1。"""
    depth = 0
    i = open_index
    in_string = False
    while i < len(text):
        ch = text[i]
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1

def split_top_level(text):
    """按深度 0 的逗号切分（括号 / 方括号 / 花括号都算深度）。"""
    parts = []
    depth = 0
    in_string = False
    start = 0
    i = 0
    while i < len(text):
        ch = text[i]
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append(text[start:i])
            start = i + 1
        i += 1
    parts.append(text[start:])
    return parts

def argument_labels(inner):
    """从参数列表文本里取出标签序列（`label: value` 形式）。"""
    labels = []
    for part in split_top_level(inner):
        matched = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*:", part.strip())
        if matched:
            labels.append(matched.group(1))
    return labels

_SWIFT_SOURCES = None

def swift_sources():
    """Seal/ 与 SealTests/ 下的全部 Swift 文件（进程内只枚举一次）。

    变异检查会把 `violations()` 跑 70+ 遍，每遍都 rglob 一次目录纯属浪费；
    实测这一步和下面的 strip_comments 缓存一起把守卫从近 3 分钟压回 40 秒内。
    """
    global _SWIFT_SOURCES
    if _SWIFT_SOURCES is None:
        _SWIFT_SOURCES = sorted(
            list((ROOT / "Seal").rglob("*.swift"))
            + list((ROOT / "SealTests").rglob("*.swift"))
        )
    return _SWIFT_SOURCES


def violations(load=read):
    failures = []
    checks = 0
    def check(ok, message):
        nonlocal checks
        checks += 1
        if not ok:
            failures.append(message)

    # 每遍（= 每个变异）内的读取与去注释结果都只算一次。
    # 注意缓存必须在**单遍**作用域内：变异检查每遍喂进来的 load 都指向被改写过的内容，
    # 跨遍缓存会读到陈旧文本，让变异检查静默失效。
    _raw_cache = {}
    _stripped_cache = {}
    # 必须先把原始 loader 绑到另一个名字再重绑 `load`：闭包里引用 `load` 会指向
    # 重绑后的自己，直接 RecursionError（实测踩到）。
    original_load = load

    def load_cached(path):
        if path not in _raw_cache:
            _raw_cache[path] = original_load(path)
        return _raw_cache[path]

    def strip_cached(path):
        if path not in _stripped_cache:
            _stripped_cache[path] = strip_comments(load_cached(path))
        return _stripped_cache[path]

    load = load_cached

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

    # R07: `UIControl.sendAction(_:to:for:)` 的返回类型是 Void，不是 Bool。
    # 2026-09-16 CI 因 `return UIControl().sendAction(...)` 编译失败（exit 65）：
    #   SigningProgressView.swift:645:28: error: cannot convert return expression of
    #   type 'Void' to return type 'Bool'
    # 「借 UIControl 发消息」是触发私有 selector 的经典写法，很容易顺手当成返回 Bool 用。
    # 需要判断「转场是否生效」时必须换判据（本项目改成「给足时间后进程是否仍存活」）。
    signing_progress_view = load("Seal/Features/Apps/SigningProgressView.swift")
    check("return UIControl().sendAction" not in signing_progress_view,
          "R07: UIControl.sendAction returns Void, not Bool — cannot be returned")

    # R08: 设备端旧描述文件清理必须覆盖扩展，且必须「有明确记录才删」（2026-09-16）。
    # 真机现象（StikDebug 的 App Expiry 页）：Seal 自己累积 17 份 profile，
    # LiveContainer 的 ShareExtension 一天内累积 6 份。两个原因：
    #   1. 安装后的清理只按**主** Bundle ID 匹配，扩展的 profile 从头到尾没人管；
    #   2. 清理只在安装成功那一刻触发，维护作业里根本没有这一步，所以历史堆积清不掉。
    # 反面约束同样重要：删错 profile 会让已安装的 App 立刻无法启动（iOS 启动时校验
    # profile 是否还在设备上），所以「拿不到可信的保留 UUID」时必须整条跳过，
    # 绝不能猜「保留最新那份」。
    profile_reader = load("Seal/Infrastructure/Installation/SignedArtifactProfileReader.swift")
    check("static func embeddedProfiles" in profile_reader
          and "isInstalledAppProvision(entry.path)" in profile_reader,
          "R08: cleanup must know every installed profile, including extensions")
    # 扩展包后缀是 .appex（本仓 SigningWorkspace / AppBundleSigningIdentityReader /
    # ApplePortalSigningService 都用 pathExtension == "appex"）。只认 .app 会静默漏掉
    # 全部扩展 —— 守卫全绿但扩展清理根本没生效，是「绿着坏掉」的典型。
    check('container.hasSuffix(".app") || container.hasSuffix(".appex")' in profile_reader,
          "R08: extensions are .appex — matching only .app silently disables extension cleanup")
    cleaner_source = load("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift")
    check("skipped-no-managed-bundle-ids" in cleaner_source,
          "R08: an empty keep-map must delete nothing")
    sweep_body = section(
        cleaner_source,
        "private static func removeProfiles(",
        "extension DeviceProfileCleaner: StaleProfileSweeping"
    )
    sweep_clean = squash(strip_comments(sweep_body))
    # 删除的**唯一**入口是局部函数 `removeProfile`（避免两条路径各写一遍 do/catch ——
    # 那种重复迟早漂移成「修了一条、漏了另一条」）。两条路径都必须先取得「凭什么可以删」：
    #   路径 1：keep-map 命中 ⇒ 知道该留哪一份；
    #   路径 2：设备端核验通过 ⇒ 见 R11。
    # 2026-09-17 重构成「先本地筛候选、再统一核验」之后，原「lookup 必须在 remove 之前」的
    # **行序**断言不再成立（`removeProfile` 被抽成局部函数、定义在循环之前），改成守这个形状。
    check("if let keepingUUID = keepingByBundleID[loweredBundleID]" in sweep_clean,
          "R08: a profile may only be deleted after its managed bundle-id lookup succeeded")
    coordinator_source = load("Seal/Core/Signing/SigningCoordinator.swift")
    check("SignedArtifactProfileReader.embeddedProfiles(in: signedData)" in coordinator_source,
          "R08: post-install cleanup must use the whole embedded profile set")
    maintenance_source = load("Seal/Core/Maintenance/AppMaintenanceJob.swift")
    check("profileSweeper" in maintenance_source and "profileKeepMap" in maintenance_source,
          "R08: idle maintenance must sweep stale device profiles")
    check("guard let uuid = record.provisioningProfileUUID" in maintenance_source,
          "R08: records without a profile UUID must be skipped, never guessed")
    # 自替换结算清理（R11 里要用）：它是**唯一**能回收 Seal 自己那批 Team 变体的路径，
    # 而它的保留集合只有 Seal 一个条目 ⇒ 其它 App 全靠宽松受保护集合兜住。
    registrar_source = load("Seal/Core/Renewal/SelfAppRegistrar.swift")
    # 扩展记录是「乐观值」：applySigningResult 在签名阶段就写它，不等安装校验。
    # 签名成功但安装失败时，扩展记录指向一份设备上不存在的 profile ——
    # 拿它当保留集合会删掉真正在用的那一份，扩展当场失效。
    check("guard record.signedArtifactStatus == .installed else { continue }" in maintenance_source,
          "R08: extension profile ids are optimistic — only trust them after a verified install")
    # R08: 清理链路的两个「静默失效」入口（2026-09-17 真机取证）。
    #
    # 真机日志：`描述文件清理：扫描 0，匹配 0，删除 0，中断于 dump，首个错误：NoDevice`。
    # 15 秒正好是 `MuxerConstants.deviceFetchTimeoutMs`，说明 `Provision.dumpProfiles`
    # 内部轮询超时后**一次都没重试**就整轮放弃。而两个触发点的时机都**不保证设备已连上**：
    # 安装后清理紧随安装（RSD 连接可能正在重建），维护期清理在 App 启动时
    #（LocalDevVPN 隧道可能还没起来）。同一账号的历史日志里清理是有成功记录的
    #（`删除 1` / `删除 3`）—— 所以问题不是「清理不可用」，而是「撞上瞬时不可达就白丢一次
    # 机会」，而下一次机会要等到下次安装或下次启动，profile 在此期间继续累积。
    check("private static let dumpAttemptLimit = 3" in cleaner_source,
          "R08: a transient NoDevice must not throw away the whole cleanup round")
    # 重试必须真的「先重置 provider 再等一等」：provider 可能缓存着一条已经断开的 RSD 连接，
    # 不重置的话三次重试全走同一条死路，等于没重试（函数还在、循环还在，约束已经失效）。
    dump_body = squash(strip_comments(section(
        cleaner_source,
        "private static func dumpProfiles(",
        "private static func removeProfiles("
    )))
    check("for attempt in 1...dumpAttemptLimit" in dump_body
          and "Provision.resetProvider()" in dump_body
          and "Task.sleep(nanoseconds: dumpRetryDelayNanoseconds)" in dump_body,
          "R08: retrying the dump without resetting the cached provider retries the same dead link")
    # 调用点必须走这个带重试的包装。直接调 `Provision.dumpProfiles` 会让重试形同虚设。
    check("try await dumpProfiles(docsPath: workingDir.path)" in sweep_clean
          and "Provision.dumpProfiles" not in sweep_clean,
          "R08: the sweep must go through the retrying dump wrapper")
    # 试了几次必须进摘要 —— 否则下次真机还是「扫描 0，匹配 0，删除 0」，
    # 看不出是设备没连上还是清理逻辑本身坏了。
    check("summary.dumpAttempts = dump.attempts" in cleaner_source,
          "R08: the retry count is the only evidence that the device was unreachable")
    # 源码断言只能证明字段被赋值，证明不了它**真的出现在日志里** —— 那是单测的活。
    # 同时断言「单测文件里的关键断言确实存在」，防止测试被删空后守卫仍然全绿。
    profile_cleaner_tests = load("SealTests/Installation/DeviceProfileCleanerTests.swift")
    check("dumpAttempts: 3" in profile_cleaner_tests
          and 'contains("，dump 尝试 3 次")' in profile_cleaner_tests
          and "func retriedDumpIsReported()" in profile_cleaner_tests,
          "R08: the retry count must stay covered by a real unit test")
    # R08: 「维护为什么没跑」必须可归因（同一次真机取证）。
    #
    # `AppMaintenanceJob` 第 4 步是**唯一覆盖全部 Seal 管理 App** 的描述文件清理路径，
    # 它那条日志是无条件写的，但真机日志里一次都没出现过（而 `系统` 类别在导出里确实存在，
    # 有 9 条）⇒ 维护要么根本没被调用，要么落在 `.skipped` / `.failed` 上。
    # 而这两个分支原先一个只有 `break`、一个只弹窗，**都不写日志** ⇒ 完全无法归因，
    # profile 堆积看起来像清理逻辑坏了（实际可能只是每轮都撞上前台操作）。
    apps_clean = strip_comments(load("Seal/Features/Apps/AppsViewModel.swift"))
    maintenance_body = section(apps_clean, "func runMaintenanceIfIdle()", "func fullEmail(for account:")
    for case_start, case_end, code in (
        ("case .skipped:", "case .completed(let report):", "SEAL-STORAGE-009"),
        ("case .aborted(let stage, let reason):", "case .failed(let failure):", "SEAL-STORAGE-006"),
        ("case .failed(let failure):", "return outcome", "SEAL-STORAGE-010"),
    ):
        branch = section(maintenance_body, case_start, case_end)
        check("logStore?.append(" in branch and code in branch,
              "R08: every non-.completed maintenance outcome must leave a trace — "
              "otherwise profile buildup is unattributable (" + code + ")")
    # R08: 自替换结算清理也必须落日志（同一次真机取证）。
    #
    # 这是**唯一**会回收 Seal 自己那份堆积的路径 —— Seal 的自更新不走 `installSignedIPA`，
    # 所以「安装后旧描述文件清理」那条根本轮不到它。而它原先只把摘要写进**事务审计**
    #（`finishCleanup` → `store.close(cleanupSummary:)`），事务审计只在 App 内部可读，
    # 排障时能拿到的只有日志 ⇒ 真机上 Seal 堆了 16 份旧 profile，日志里查不出任何原因。
    registrar_clean = squash(strip_comments(load("Seal/Core/Renewal/SelfAppRegistrar.swift")))
    check("try? await logStore?.append(" in registrar_clean
          and "自替换结算清理：" in registrar_clean
          and registrar_clean.index("自替换结算清理：") < registrar_clean.index("finishCleanup(cleanup)"),
          "R08: the self-replacement cleanup must log before closing the transaction — "
          "the transaction audit is not readable during triage")
    # 同上：源码断言证明不了「日志真的落下来了」（`logStore` 没注入 / 消息被脱敏吃掉都会静默失效）。
    handoff_tests = load("SealTests/Renewal/SelfAppPendingHandoffTests.swift")
    check("func confirmedReplacementLogsCleanupSummary()" in handoff_tests
          and 'hasPrefix("自替换结算清理：")' in handoff_tests,
          "R08: the self-replacement cleanup log needs a real unit test")

    # R11: 「换 Apple ID 后旧 Team 后缀」的 profile 回收（2026-09-17）。
    #
    # 起因：用户轮换多个 Apple ID 突破免费账号「3 个自签应用」上限，而 `BundleIDMapper`
    # 强制附加**当前** team 后缀 ⇒ 每换一个账号，每个 App 就多一个 Bundle ID。
    # 从 19 份真机日志量化：**19 个 base × 13 个 team = 39 个 Seal 生成过的 Bundle ID**，
    # 而 keep-map 的 key 只有当前在用的那些 ⇒ 历史后缀的 profile 永远进不了 `matched`，
    # `删除` 恒为 0（真机 `扫描 325，匹配 1，删除 0`）。
    #
    # 这是**设备端破坏性操作**：删错一份，对应 App 立刻无法启动（iOS 启动时校验 profile）。
    # 所以判据必须钉死，而且要注意「绿着坏掉」的写法 —— 形态判据、单测、日志全都还在，
    # 但安全性已经被悄悄抽掉的那种改法。
    reclaim_source = strip_comments(load("Seal/Core/Maintenance/ProfileReclaimPolicy.swift"))
    # ① 形态判据只认 `.seal.` 中缀。其它工具（AltStore / SideStore）用 `<原始>.<teamID>`，
    #    没有这个中缀 ⇒ 天然不会碰别人的 App。
    check('static let sealGeneratedMarker = ".seal."' in reclaim_source,
          "R11: the orphan marker must stay the dotted form — '.seal' would also match xseal.y")
    # ①b keep-map 的命中判断必须**大小写不敏感**。
    #    写成 `keepingByBundleID[lowered] == nil` 这种精确查表时，只要 key 的大小写
    #    与设备端不一致，就会把「正在用的那个」判成可回收 ⇒ 删掉活着的 profile。
    #    调用方目前确实会把 key 归一化成小写，但**这条判断的错法方向是删数据**，
    #    不能靠调用方约定来保证安全 —— 2026-09-17 就是被单测当场证伪的。
    check("keepingByBundleID.keys.contains(where: { normalized($0) == lowered })"
          in reclaim_source,
          "R11: the keep-map membership test must be case-insensitive — a case mismatch "
          "would classify a live profile as reclaimable")
    # ①c **两个集合必须分开**（2026-09-17 真机事故的修法）。
    #
    #    判据是「不在保留集合里 ⇒ 成为候选」，所以「保留集合漏了谁」会直接变成「删掉谁」。
    #    严格集合（`keepingByBundleID`）刻意宁缺勿滥 —— 拿不到可信 UUID 就不进集合；
    #    宽松集合（`protectedBundleIDs`）宁滥勿缺 —— 记录里出现过就进。
    #    一旦有人把后者合并进前者（或干脆删掉后者），**已装 App 的扩展 profile 会被删掉**：
    #    扩展不是独立安装的 App，`isAppInstalled` 对它恒为 `false`，
    #    设备端核验这道安全网对扩展完全是瞎的。
    #    真机日志（构建 95）：`候选 4，回收 3，已装保留 1`，示例里主 App 与它的三个扩展并列。
    check("protectedBundleIDs: Set<String>" in reclaim_source
          and "protectedBundleIDs.contains(where: { normalized($0) == lowered })"
          in reclaim_source,
          "R11: the candidate rule needs a separate protected set — without it, extension "
          "profiles of installed apps are reclaimed (device probing can't see extensions)")
    # ①d 宽松集合的构造**不得**受 `signedArtifactStatus` 门槛影响。
    #    严格 keep-map 要求 `.installed` 才收扩展（那个取舍是对的），但那个标记一旦陈旧，
    #    扩展 ID 就掉出保护范围 ⇒ 被当孤儿删掉。
    protected_parts = reclaim_source.split("static func protectedBundleIDs(records:", 1)
    protected_body = squash(protected_parts[1]) if len(protected_parts) > 1 else ""
    check(protected_body != ""
          and "signedArtifactStatus" not in protected_body
          and "record.extensions" in protected_body,
          "R11: the protected set must collect extensions unconditionally — gating it on "
          "signedArtifactStatus is exactly how live extension profiles got deleted")
    # ①e 两个集合必须真的**贯通到设备层**，不能只在判据里存在。
    #    判据再对，调用方传个空集合也等于没有保护。
    for name, source in (("idle maintenance", maintenance_source),
                         ("post-install cleanup", coordinator_source),
                         ("self-replacement settle", registrar_source)):
        check("ProfileReclaimPolicy.protectedBundleIDs(records:" in squash(strip_comments(source)),
              f"R11: {name} must pass a record-derived protected set")
    # ①f 受保护集合为空时**整轮不回收**（fail closed）。
    #    记录读不到 ⇒ 保护范围未知 ⇒ 宁可这一轮不回收，也不能按「现有信息尽量删」办。
    check("let reclaimEnabled = reclaimSealOrphans && protectedBundleIDs.isEmpty == false"
          in squash(strip_comments(cleaner_source)),
          "R11: an empty protected set must disable reclaim entirely (fail closed)")
    # ② 决策函数是**唯一**的安全边界，三个分支缺一不可。
    #    `.notInstalled` 必须**问过阳性对照**才可能返回 `.reclaim` —— 这是最容易被
    #    「简化」掉的一句：直接 `return .reclaim` 之后，形态判据与单测全都还在，
    #    功能看起来完全正常，但「隧道抖动 ⇒ 全部答成未安装 ⇒ 全删」的路径就敞开了。
    decision_parts = reclaim_source.split("static func decision(", 1)
    decision_body = squash(decision_parts[1]) if len(decision_parts) > 1 else ""
    check("case .unavailable: return .abortPass" in decision_body,
          "R11: a failed probe must abort the pass — it must never be read as 'not installed'")
    check("case .installed: return .keepInstalled" in decision_body,
          "R11: an installed app's profile must always be kept")
    check("return positiveControlPassed ? .reclaim : .abortPass" in decision_body,
          "R11: .reclaim must require a passed positive control")
    # ③ 设备层必须用会**抛错**的 `isAppInstalled`，而不是 `lookupApp`：
    #    `Minimuxer.lookupApp` 返回 `String?`，把「没装」与「查询失败」**折叠成同一个 nil**
    #    （`Minimuxer.swift:254` 里 `try?` 吞掉错误、`Device.getFirstDevice()` 失败也返回 nil）。
    #    拿它当判据 ⇒ 隧道一抖动，所有候选都被读成「没装」⇒ 删掉正在用的 profile。
    reclaim_body = squash(strip_comments(section(
        cleaner_source,
        "private static func probeInstalled(",
        "extension DeviceProfileCleaner: StaleProfileSweeping"
    )))
    check("try Minimuxer.isAppInstalled(bundleId: bundleID)" in reclaim_body,
          "R11: the reclaim path must use the throwing isAppInstalled")
    check("Minimuxer.lookupApp(" not in reclaim_body,
          "R11: lookupApp's nil means both 'not installed' and 'query failed' — "
          "reading it as 'not installed' deletes profiles of installed apps")
    # ④ 阳性对照必须**真的是设备查询**，且必须在删任何一份之前跑完。
    #    把 `== .installed` 改成 `= true` 能让对照永远通过 —— 通道不可信时照样全删。
    check("let positiveControlPassed = await probeInstalled(bundleID: controlBundleID) == .installed"
          in reclaim_body,
          "R11: the positive control must be an actual probe of a definitely-installed app")
    control_at = reclaim_body.find("probeInstalled(bundleID: controlBundleID)")
    candidate_at = reclaim_body.find("ProfileReclaimPolicy.decision(")
    check(control_at != -1 and candidate_at != -1 and control_at < candidate_at,
          "R11: the positive control must run before any candidate is probed or deleted")
    # ⑤ `.abortPass` 必须**中止整轮**，而不是只跳过当前这一条。
    #    只跳过的话，后面的候选会继续被一条已经不可信的通道「判定」，等于没有保护。
    #
    #    2026-09-17 改成「先问完所有候选、再决定」之后，中止的形状变成
    #    「循环外 `guard … else { 记录原因; return }`」—— 语义比原来更强：
    #    **连已经问过的那几条也不删**（半路删掉一部分再中止，等于用一条已判定不可信的
    #    通道做了一半不可逆的事）。所以断言也跟着改成这个形状。
    check("case .abortPass:" in reclaim_body
          and "guard reclaimAbortReason == nil else { summary.reclaimAborted = "
              "reclaimAbortReason return summary }" in reclaim_body
          and reclaim_body.count("summary.reclaimAborted =") >= 2,
          "R11: .abortPass must record why and stop the whole pass")
    # ⑥ 中止必须进日志，且不能借用 `中断于`（那会让人以为整轮清理白跑了，
    #    而路径 1 的成绩其实仍然有效）。
    check("if let reclaimAborted" in cleaner_source
          and '"，回收中止：' in cleaner_source,
          "R11: an aborted reclaim must be visible — otherwise '回收 0' is misread "
          "as 'no candidate matched the marker'")
    # ⑦ 两个调用点都必须**显式**开启回收；默认值必须仍是 false（默认删设备数据是不可接受的）。
    check(cleaner_source.count("reclaimSealOrphans: Bool = false") == 2,
          "R11: orphan reclaim must stay opt-in at every entry point")
    check(squash(strip_comments(maintenance_source)).count("reclaimSealOrphans: true") == 1,
          "R11: idle maintenance must opt in explicitly")
    check(squash(strip_comments(coordinator_source)).count("reclaimSealOrphans: true") == 1,
          "R11: post-install cleanup must opt in explicitly")
    # ⑧ 源码断言只能证明「逻辑在」，证明不了每个分支**真的被测过** —— 那是单测的活。
    reclaim_tests = load("SealTests/Maintenance/ProfileReclaimPolicyTests.swift")
    check("func notInstalledWithHealthyChannelIsTheOnlyReclaimPath()" in reclaim_tests
          and "func unavailableNeverReclaims()" in reclaim_tests
          and "func failedPositiveControlAbortsTheWholePass()" in reclaim_tests
          and "func noCandidateIsEverReclaimedWhenPositiveControlFails()" in reclaim_tests,
          "R11: every branch of the reclaim decision needs a real unit test")
    # 大小写不敏感那条必须有**用混合大小写 key** 的单测。把 key 改成小写就能让
    # 上面那条源码断言（断言实现里写了 `lowercased()` 比较）继续绿着 ——
    # 所以这里要单独钉住「测试用的确实是混合大小写的 key」。
    case_test = section(
        reclaim_tests,
        "func currentBundleIdentifierIsNeverACandidate()",
        "func matchingIsCaseInsensitive()"
    )
    check('"com.kdt.livecontainer.seal.KYRJV2U7WS": "LIVE-UUID"' in case_test,
          "R11: the keep-map case-insensitivity needs a real unit test with a mixed-case key")
    check("func reclaimAbortIsVisibleWithoutClaimingTheWholeRunFailed()" in profile_cleaner_tests,
          "R11: the reclaim summary needs a real unit test")
    # 「开关漏传」是这条功能最典型的静默失效：`reclaimSealOrphans` 是个 Bool，
    # 漏传时编译不失败、别的单测也不红，只是旧 Team 的 profile 永远清不掉 ——
    # 而这正是用户报的那个现象。所以要有一条专门断言「调用方真的开了」的单测。
    maintenance_tests = load("SealTests/Maintenance/AppMaintenanceJobTests.swift")
    check("func maintenanceSweepEnablesSealOrphanReclaim()" in maintenance_tests
          and "receivedReclaimFlags" in maintenance_tests,
          "R11: the opt-in flag must stay covered by a real unit test")
    # 受保护集合必须有单测，而且必须覆盖**两个方向**：
    #   ① 扩展 ID 在集合里 ⇒ 不是候选（真机事故的直接修法）；
    #   ② 同一个 ID **不**在集合里 ⇒ 确实是候选（否则 ① 可能只是因为「形态没匹配上」而通过，
    #      也就是绿着坏掉 —— 判据被删空时测试照样全绿）。
    check("func protectedExtensionIsNeverACandidate()" in reclaim_tests
          and "func extensionIsCollectedEvenWhenRecordIsNotMarkedInstalled()" in reclaim_tests,
          "R11: the protected set needs real unit tests (extension protected / still a "
          "candidate without protection)")
    protected_test_body = section(
        reclaim_tests,
        "func protectedExtensionIsNeverACandidate()",
        "func protectedSetMatchingIsCaseInsensitive()"
    )
    check(protected_test_body.count("protectedBundleIDs: [extensionID]") >= 1
          and protected_test_body.count("protectedBundleIDs: []") >= 1,
          "R11: the protected-set test must assert both directions — with and without "
          "protection — or it passes for the wrong reason")
    # 构造侧：不得出现 `signedArtifactStatus` 门槛（源码断言已守实现，这里守**单测真的钉住了它**）。
    check("func extensionIsCollectedWhenStatusIsNil()" in reclaim_tests,
          "R11: the protected set must be tested with a nil install status")
    # 三个调用点各自要有单测证明「真的传下去了」。
    check("func protectedSetCoversExtensionsEvenWhenRecordIsNotMarkedInstalled()" in maintenance_tests,
          "R11: idle maintenance must prove it passes the protected set")
    settle_tests = load("SealTests/Renewal/SelfAppPendingHandoffTests.swift")
    check("func settleCleanupCarriesProtectedBundleIDsForOtherAppsExtensions()" in settle_tests,
          "R11: self-replacement settle cleanup must prove it passes the protected set — "
          "its keep-map only holds Seal itself, so extensions have no other protection")

    # R12: 批量续签的逐项成功日志 + 轮询日志降噪（2026-09-17 真机日志驱动）。
    #
    # ① 批量续签原来**一条逐项结果都不写** —— 「续签并安装成功」只在**单签**的
    #    `AppsViewModel.signAndInstall` 里写，而批量走的是 `RenewalCoordinator` →
    #    `SigningCoordinator.signAndInstall`。后果是真机上「某个 App 到底成没成」
    #    只能靠推断：2026-09-17 用户续签 LiveContainer 后界面停在「安装中」，
    #    取消后看到 App 像是重装了，却无法确认装没装上、描述文件是不是新申请的。
    #    排障入口只有导出的日志，而当时日志里**一个字都没有**。
    renewal_source = strip_comments(load("Seal/Core/Renewal/RenewalCoordinator.swift"))
    check('"SEAL-RENEW-020"' in renewal_source
          and "Self.describeProfile(updated)" in renewal_source,
          "R12: the batch renewal path must log a per-item success line")
    # 这条日志必须带上**描述文件身份**（UUID + 创建/到期时间）。
    # 只写「成功」两个字回答不了那个真正的问题：「换的是新申请的那份，还是旧的那份」。
    # 断言的是 `describeProfile` 的**函数体**而不是整个文件 —— 后者在函数被改成
    # `return ""` 时照样通过（定义还在，只是不再产出任何字段）。
    # 用 `section()` 而不是 `split(...)[1]`：后者会取到**文件尾**，
    # 于是「函数体里有没有这个字段」变成了「文件后面还有没有这个字段」。
    profile_body = squash(section(
        renewal_source,
        "static func describeProfile(",
        "private func emitFailure("
    ))
    check(profile_body != ""
          and "provisioningProfileUUID" in profile_body
          and "provisioningProfileCreationDate" in profile_body
          and "provisioningProfileExpirationDate" in profile_body
          and "ISO8601DateFormatter" in profile_body,
          "R12: the per-item success line must carry the profile identity (UUID + creation "
          "+ expiry), ISO8601-formatted so it can be compared with Apple's portal")
    # 实参漏传不会编译失败，只会让这条日志重新变成空白 —— 与 `reclaimSealOrphans`
    # 属同一类静默失效（见 R11 ⑦）。必须限定在 `RenewalCoordinator` 的构造块里查：
    # `logStore: logStore` 在 `AppContainer` 里出现 8 次，全局匹配会让
    # 「只删掉这一处」的变异检不出来。
    renewal_init = section(
        load("Seal/Application/AppContainer.swift"),
        "let renewalCoordinator = RenewalCoordinator(",
        "let appRecordRecovery"
    )
    check("logStore: logStore" in squash(renewal_init),
          "R12: the batch coordinator must be given a log store — a missing argument "
          "compiles fine and silently blanks the per-item log again")
    # 源码断言只能证明「字段被写出来了」，证明不了格式化真的产出了 UUID 与时间
    # （可能被脱敏吃掉、字段可能是 nil）。所以那条日志里唯一可测的纯函数要有单测，
    # 而且单测必须断言**完整**的 ISO8601 形态 —— 断言 `contains("T")` 这种单字符会
    # 同时匹配 `contains(_: Character)` 与 `contains(_: String)`，宏展开难以预料。
    log_tests = load("SealTests/Renewal/RenewalCoordinatorLogTests.swift")
    check("func profileIdentityIncludesUUIDAndBothDates()" in log_tests
          and "func missingDatesAreSpelledOutRatherThanOmitted()" in log_tests,
          "R12: the per-item success line needs a real unit test for its profile identity")
    check('"2026-09-17T05:28:58Z"' in log_tests,
          "R12: the ISO8601 unit test must assert the full form, not a single character")

    # ② 轮询日志必须保持删除状态（2026-09-17 真机日志量化）。
    #
    # `restorePendingBatchResultIfNeeded` 由 `load()` 每 ~9 秒调用一次，而
    # 「没有待恢复的数据」与「当前有会话在进行」都是**正常路径**。
    # 那两条是 09-16「93 秒空白」排查时加的临时脚手架，实测占了全部日志的
    # **30%（73/244 行）**，把真实信号挤出了只保留 1000 条的环形缓冲。
    view_model_code = strip_comments(load("Seal/Features/Apps/AppsViewModel.swift"))
    check("[BatchDebug]" not in view_model_code,
          "R12: the temporary [BatchDebug] scaffolding must stay removed — it was 30% of "
          "the log ring buffer and pushed real signal out")
    # 但「**确实有待恢复的数据、却被跳过**」是异常，仍要留痕 —— 那才是「结果丢了」的
    # 征兆。两条一起断言：正常路径静默（裸 `return`）＋ 异常路径有条件日志。
    restore_body = squash(section(
        view_model_code,
        "private func restorePendingBatchResultIfNeeded()",
        "private func clearPendingBatchResult()"
    ))
    check(restore_body != ""
          and "guard let payload = pendingPayload else { return }" in restore_body
          and "if pendingPayload != nil {" in restore_body,
          "R12: the restore poll path must stay silent on the normal path — only "
          "'pending data exists but the restore was skipped' deserves a log line")

    # R13: 「Apple 要求双重认证」必须走专门的分类与提示（2026-09-17 真机取证，构建 95）。
    #
    # 加这条之前，Apple 返回 `Code：3018 / requires signing in with two-factor
    # authentication` 时界面给的是「Apple ID 验证失败 / 重试；如持续失败请核对
    # Apple ID 与密码」—— 而**密码完全没问题**：Apple 已经接受了密码，只是要求走第二步。
    # 用户会在一个正确的密码上反复试，甚至跑去重置密码。
    # 这类错法不崩、不编译失败，只在真机上把用户引错方向 ⇒ 判据与文案抽成纯函数
    # （`AppleAuthenticationDiagnosis`）+ 单测 + 守卫。
    diagnosis_source = strip_comments(
        load("Seal/Infrastructure/Accounts/AppleAuthenticationDiagnosis.swift")
    )
    check("static let twoFactorRequiredCode = 3018" in diagnosis_source,
          "R13: the two-factor error code must stay 3018 — it is the only stable "
          "identifier Apple gives (the description is localised and gets reworded)")
    # 判据必须**先认错误码**：描述会随 Apple 的措辞与语言变，错误码不会。
    # 描述只做兜底（万一 Apple 换码），不能成为唯一依据。
    check("if nsError.code == twoFactorRequiredCode { return true }" in diagnosis_source,
          "R13: the code check must come first and stand on its own — matching only on "
          "the description breaks the moment Apple rewords or localises it")
    # 这是整条功能的**全部意义**：提示里不能把用户引向一个正确的密码。
    # 源码断言只能证明「有这么个工厂」，证明不了它的文案 ⇒ 真正的护栏是单测（见下），
    # 这里额外钉住那个工厂没有去复用泛化文案。
    check("核对 Apple ID 与密码" not in diagnosis_source,
          "R13: the two-factor prompt must not reuse the generic 'check your Apple ID "
          "and password' advice — the password is exactly what is NOT the problem")
    check('code: "SEAL-AUTH-101a"' in diagnosis_source,
          "R13: the two-factor failure needs its own code so it is greppable in logs")

    # 三个映射入口：`make`（新账号登录）、`validate`（已存 session 重新验证）、
    # `failure(from:)`（Anisette 前置失败后的通用兜底）。
    # 「只在其中一条链路上加」是这类修复最容易犯的错，而且不崩、不编译失败。
    client_source = strip_comments(load("Seal/Infrastructure/Accounts/AppleAccountClient.swift"))
    check(client_source.count("AppleAuthenticationDiagnosis.isTwoFactorRequired(error)") == 3,
          "R13: every error-mapping entry point must route the two-factor error — "
          "covering only one path silently re-introduces the wrong advice elsewhere")
    check(client_source.count("AppleAuthenticationDiagnosis.twoFactorFailure(for: error)") == 3,
          "R13: every entry point must use the shared factory, not a hand-written prompt — "
          "two copies drift and only one of them gets fixed")

    # 顺序也是设计：双重认证是最具体的诊断（Apple 已接受密码），必须排在限流/网络之前。
    # 两个入口顺序不一致时，同一个错误在两条路径上会给出不同提示。
    # 断言的是**每个函数体内的相对位置**，不是「文件里有没有这两个字符串」。
    for entry_name, start_marker, end_marker in (
        ("AppleAuthenticationFailure.make",
         "static func make(stage: AppleAuthenticationStage, error: Error) -> ImportFailure {",
         "case .teamLookup:"),
        ("AppleAccountClient.validate",
         "func validate(",
         "nonisolated static func mask(_ appleID: String) -> String {"),
        ("AppleAccountClient.failure(from:)",
         "private nonisolated static func failure(from error: Error) -> ImportFailure {",
         "private struct AuthObjects"),
    ):
        entry_body = section(client_source, start_marker, end_marker)
        two_factor_at = entry_body.find("isTwoFactorRequired(error)")
        rate_limit_at = entry_body.find("isRateLimited(error)")
        check(two_factor_at != -1 and rate_limit_at != -1 and two_factor_at < rate_limit_at,
              f"R13: {entry_name} must check two-factor before rate-limit/network — "
              "the more specific diagnosis has to win")

    # 新错误码**不能**落进「凭据失效」那一组：那会把账号标成需要重新验证，
    # 而这里账号和密码都是好的，只是第二步没走完。
    policy_source = strip_comments(
        load("Seal/Core/Accounts/AppleServiceFailurePolicy.swift")
    )
    check("SEAL-AUTH-101a" not in policy_source,
          "R13: the two-factor failure must not be classified as credentials-rejected — "
          "the password is fine, marking the account as needing re-verification is wrong")

    # 源码断言只能守「形状」，守不住「文案真的没把用户引错」。所以那几条必须由单测承担，
    # 守卫反过来钉住「这些单测确实存在」—— 防止测试被删空后仍然全绿。
    diagnosis_tests = load("SealTests/Accounts/AppleAuthenticationDiagnosisTests.swift")
    check("func code3018IsRecognisedAsTwoFactorRequired()" in diagnosis_tests
          and "func descriptionMarkerIsTheFallbackWhenTheCodeDiffers()" in diagnosis_tests,
          "R13: the two-factor classification needs a real unit test")
    check("func twoFactorFailureNeverTellsTheUserToCheckThePassword()" in diagnosis_tests,
          "R13: the 'never send the user to check the password' rule is the whole point "
          "of this fix — it must be pinned by a unit test, not just by prose")
    check("func makeRoutes3018ToTheTwoFactorFailure()" in diagnosis_tests,
          "R13: testing the classifier alone would not catch a removed branch in `make` — "
          "the routing itself needs an end-to-end assertion")
    check("func twoFactorFailureIsNotClassifiedAsCredentialsRejected()" in diagnosis_tests,
          "R13: the 'not credentials-rejected' boundary needs a unit test")

    # R14: 两条安装路径共用同一个心跳 + 扩展随父 App 保留（2026-09-17 真机，构建 97）。
    #
    # ① 普通安装卡了 **9 分多钟**，日志里从「开始安装」到用户导出日志**一行都没有** ——
    #    因为心跳当时只加在**自替换**那条路径上。同一条规则只落在两条链路中的一条，
    #    是本仓库反复踩到的形态（`InstallStageTimeline` 那次也是）。
    #    判据：心跳必须是一个共用实现，两条路径都走它。
    install_source = strip_comments(
        load("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift")
    )
    check("private func beginInstallHeartbeat(" in install_source,
          "R14: the install heartbeat must be ONE shared helper — two copies drift, "
          "and only one of them gets fixed")
    check(install_source.count("beginInstallHeartbeat(") == 3,
          "R14: BOTH install paths must use the shared heartbeat "
          "(1 definition + 2 call sites). A normal install that hangs logs nothing without it")
    check('let heartbeat = beginInstallHeartbeat("安装")' in install_source
          and 'beginInstallHeartbeat("自替换安装")' in install_source,
          "R14: each path needs its own label, and the normal path must start the "
          "heartbeat before it blocks on the synchronous FFI")
    check("selfReplacementHeartbeatNanoseconds" not in install_source,
          "R14: the old inline heartbeat must stay gone — a second copy is exactly how "
          "the two paths drifted apart")

    # ② 扩展随父 App 保留。扩展不是独立安装的 App，`isAppInstalled` 对它恒为 false ⇒
    #    设备端核验对扩展完全瞎。此前扩展**只**靠 `protectedBundleIDs`（记录里出现过的 ID）
    #    保护，于是「主 App 不在记录里」时扩展失去全部保护 —— 主 App 却被核验救下。
    #    真机：`候选 4，回收 3，已装保留 1`，示例里主 App 与它的三个扩展并列。
    reclaim_source = strip_comments(
        load("Seal/Core/Maintenance/ProfileReclaimPolicy.swift")
    )
    check("static func isExtensionBundleID(" in reclaim_source,
          "R14: extensions of an installed app must be recognised via the parent prefix")
    check('if lowered.hasPrefix(parent + ".") { return true }' in reclaim_source,
          "R14: the parent prefix must end on a DOT boundary — without it sibling "
          "variants would 'protect' each other and reclaim would stop working entirely")
    cleaner_source = strip_comments(
        load("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift")
    )
    check("installedCandidates.insert(ProfileReclaimPolicy.normalized(entry.bundleID))"
          in cleaner_source,
          "R14: the 'installed parent' set must be built from THIS pass's candidates — "
          "a general installed-app list would let an ordinary app's ID prefix-match "
          "every orphan and silently disable reclaim")
    # 「先问完所有候选、再决定」是这条规则的**结构前提**：扩展要等父 App 的探测结果。
    # 顺序断言用相对位置，不是「文件里有没有这几个字符串」。
    reclaim_pass = section(
        cleaner_source,
        "var probes: [(uuid: String, bundleID: String, probe: ProfileReclaimPolicy.InstallProbe)] = []",
        "extension DeviceProfileCleaner: StaleProfileSweeping"
    )
    probe_at = reclaim_pass.find("probes.append(")
    abort_at = reclaim_pass.find("guard reclaimAbortReason == nil else {")
    installed_at = reclaim_pass.find("var installedCandidates: Set<String> = []")
    remove_at = reclaim_pass.find("removeProfile(entry.uuid)")
    check(probe_at != -1 and abort_at != -1 and installed_at != -1 and remove_at != -1
          and probe_at < abort_at < installed_at < remove_at,
          "R14: the reclaim pass must probe EVERY candidate before deleting any — "
          "the extension rule needs the complete 'which candidates are installed' set, "
          "and an abort must land before anything irreversible")
    check("ofAnyOf: installedCandidates" in reclaim_pass,
          "R14: the pass must consult the parent rule with the real candidate set — "
          "passing an empty set leaves the call in place while protecting nothing")
    # 受保护集合的规模是「候选为什么这么多」的第一归因：记录读不到时它会是 0/极小。
    # 2026-09-17 的日志里只有 `候选 4，回收 3`，看不出那一刻保护范围到底有多大。
    check('，受保护 \\(protectedCount)' in cleaner_source,
          "R14: the protected-set size must be in the log — without it, 'many candidates' "
          "cannot be told apart from 'the records were not read'")

    # 两个新的归因计数必须有单测：源码断言证明不了「值真的被算出来了」。
    extension_tests = load("SealTests/Maintenance/ProfileReclaimPolicyTests.swift")
    check("func extensionOfAnInstalledCandidateIsRecognised()" in extension_tests
          and "func prefixMustEndOnADotBoundary()" in extension_tests
          and "func extensionOfANonInstalledParentIsNotProtected()" in extension_tests,
          "R14: the parent-prefix rule needs real unit tests — source assertions cannot "
          "prove the boundary behaviour")
    cleaner_tests = load("SealTests/Installation/DeviceProfileCleanerTests.swift")
    check("func protectedSetSizeIsReported()" in cleaner_tests
          and "func extensionKeptCountIsReportedSeparately()" in cleaner_tests,
          "R14: the new attribution counters need real unit tests")

    # R08: 日志导出的表头必须自带**构建标识**（2026-09-17 的取证教训）。
    #
    # `CURRENT_PROJECT_VERSION` 由 `Scripts/build-unsigned-ipa.sh` 取 `GITHUB_RUN_NUMBER`，
    # 所以它唯一对应一次 CI 构建、进而唯一对应一个提交。没有这一行时，
    # 「这份日志来自哪个构建」只能靠**比对日志文案的措辞**去反推 ——
    # 2026-09-17 实际踩到：一份日志的文案与当前源码不一致，顺着它去比对历史提交，
    # 才发现那份日志来自比修复更早的构建，整轮分析的前提都不成立。
    formatter_source = strip_comments(load("Seal/Core/Diagnostics/SealLogEntry.swift"))
    check("static var currentBuildLabel: String" in formatter_source
          and 'CFBundleShortVersionString' in formatter_source
          and 'CFBundleVersion' in formatter_source,
          "R08: the log header must identify the build it came from")
    check('"构建 \\(buildLabel)' in formatter_source,
          "R08: the build label must actually be rendered into the export header")
    # 真实导出路径必须**显式**透传：靠默认参数虽然也能工作，但这条依赖
    # 「日志能不能定版」，要能被源码断言看见 —— 删掉它守卫就该红。
    store_source = squash(strip_comments(load("Seal/Infrastructure/Diagnostics/SealLogStore.swift")))
    check("buildLabel: SealLogTextFormatter.currentBuildLabel" in store_source,
          "R08: the store must pass the build label through — otherwise exports silently lose it")
    # 源码断言只能证明「渲染逻辑在」，证明不了导出文本里真有这一行。
    formatter_tests = load("SealTests/Diagnostics/SealLogTextFormatterTests.swift")
    check("func storeExportIncludesBuildLabel()" in formatter_tests
          and "func buildLabelComesBeforeEntries()" in formatter_tests,
          "R08: the build label in the export needs a real unit test")

    # R09: 构造器实参顺序必须与声明顺序一致（2026-09-16 被 CI 拦下一次）。
    # 本机（Windows）没有 Swift 工具链，而 `build-package` **不编译测试 target** ——
    # 所以测试里 `AppRecord(...)` 的参数顺序写错会顺利通过 build-package，
    # 只在 `swift-regression` 红（exit 65），一轮 CI 白等 13 分钟。
    # 实际报错：error: argument 'ipaRelativePath' must precede argument 'signedArtifactStatus'
    def declared_argument_labels(path, marker):
        """从 `marker` 之后的第一个 `(` 解析出参数标签序列（marker 必须包含到 `(`）。"""
        source = strip_comments(load(path))
        at = source.find(marker)
        if at == -1:
            return []
        open_at = source.index("(", at + len(marker) - 1)
        close_at = match_paren(source, open_at)
        if close_at == -1:
            return []
        return argument_labels(source[open_at + 1:close_at])

    def call_order_errors(declared_labels, call_pattern, skip_paths=()):
        """校验 Seal/ 与 SealTests/ 下每个调用点的实参标签顺序与声明一致。

        返回 (错误列表, 实际扫到的调用点数)。**调用点数必须一并返回并断言下限**：
        本轮第一版把正则写成 `(?<![A-Za-z0-9_.])signAndInstall\\(`，而真实调用点全是
        `coordinator.signAndInstall(` —— 前一个字符是 `.`，被反向断言全部排除，
        于是「零调用点 ⇒ 零错误 ⇒ 检查通过」。守卫全绿但完全没在守卫任何东西，
        正是这个脚本注释里反复警告的「绿着坏掉」。
        """
        errors = []
        scanned = 0
        if not declared_labels:
            return errors, scanned
        for source_path in swift_sources():
            relative = source_path.relative_to(ROOT).as_posix()
            if relative in skip_paths:
                continue
            source = strip_cached(relative)
            for match in re.finditer(call_pattern, source):
                # 声明本身（`func name(`）不是调用点；否则会把参数默认值当成实参。
                if source[max(0, match.start() - 5):match.start()] == "func ":
                    continue
                call_open = match.end() - 1
                call_close = match_paren(source, call_open)
                if call_close == -1:
                    continue
                labels = argument_labels(source[call_open + 1:call_close])
                if not labels:
                    continue
                scanned += 1
                indices = [
                    declared_labels.index(label)
                    for label in labels
                    if label in declared_labels
                ]
                if len(indices) != len(labels) or indices != sorted(indices):
                    errors.append(relative + " -> " + ", ".join(labels))
        return errors, scanned

    # 同一类坑在 2026-09-16 一天内咬了两次：AppRecord（测试里）与 signAndInstall（本轮自己
    # 给批量续签加 onInstallProgress 时，把它写到了 broadcastsInstallStage 之后）。
    # 这类函数的特点：参数多、绝大多数带默认值、调用点几乎全是「省略中间几个」，
    # 于是把靠后的标签写到前面去看起来毫无违和感 —— 但 Swift 要求实参标签顺序与声明
    # 一致，直接 exit 65。校验的代价是几行 Python，收益是省掉一轮 13 分钟的 CI。
    # 每项：(名字, 声明文件, 声明锚点, 声明标签数下限, 调用点正则, 跳过文件, 调用点数下限)
    order_targets = (
        ("AppRecord", "Seal/Core/Apps/AppRecord.swift", "    init(", 30,
         r"(?<![A-Za-z0-9_.])AppRecord\(", ("Seal/Core/Apps/AppRecord.swift",), 10),
        ("signAndInstall", "Seal/Core/Signing/SigningCoordinator.swift",
         "func signAndInstall(", 10, r"(?<![A-Za-z0-9_])signAndInstall\(", (), 2),
        ("installSignedIPA", "Seal/Core/Signing/SigningCoordinator.swift",
         "private func installSignedIPA(", 7, r"(?<![A-Za-z0-9_])installSignedIPA\(", (), 2),
        ("installCachedSignedIPAIfPossible", "Seal/Core/Signing/SigningCoordinator.swift",
         "private func installCachedSignedIPAIfPossible(", 8,
         r"(?<![A-Za-z0-9_])installCachedSignedIPAIfPossible\(", (), 1),
    )
    for name, path, marker, min_declared, pattern, skips, min_sites in order_targets:
        declared_labels = declared_argument_labels(path, marker)
        check(len(declared_labels) >= min_declared,
              "R09: " + name + " must stay parseable by the guard")
        errors, sites = call_order_errors(declared_labels, pattern, skip_paths=skips)
        # 调用点数下限是防「绿着坏掉」的：正则写歪会扫到 0 个调用点，
        # 而 0 个调用点必然 0 个错误 —— 检查通过但什么都没守住（本轮实际踩到）。
        check(sites >= min_sites,
              "R09: " + name + " call sites must stay discoverable by the guard (found "
              + str(sites) + ")")
        check(not errors,
              "R09: " + name + " call-site labels must follow the declaration order ("
              + " | ".join(errors) + ")")

    # R10: 安装阶段必须「看得见、退得出」（2026-09-16 真机反馈）。
    # 现象一：单签停在 93%（= `.installing`，见 SigningProgressView.overallProgress）。
    # 现象二：批量续签抽屉停在「传输中」。
    # 两者是同一件事：上传完成（安装通道的 >1.0 哨兵）之后 installd 才真正开始安装，
    # 而安装期间**没有任何进度回报**；同时 UI 既没有说明也没有退出通道 ——
    # 抽屉在运行中隐藏了整个 footer 并禁用了下滑关闭，用户被关在一个静止弹窗里，
    # 感受就是「怎么都没反应」。
    #
    # 这些约束有个共同特征：改回旧写法**不会编译失败、也不会跑挂单测**，
    # 只会让真机重新「卡住」。所以必须由静态守卫钉住。
    bridge_source = load("Seal/Core/Signing/InstallStageBridge.swift")
    # 1.0 是「上传到 100%」，不是「开始安装」：用 >= 会让 UI 在设备还没动手时谎报安装中。
    check("uploadProgress > uploadCompletionSentinel" in bridge_source,
          "R10: 1.0 means 'upload finished', not 'installing' — the sentinel must be exclusive")
    install_signed_body = section(
        load("Seal/Core/Signing/SigningCoordinator.swift"),
        "private func installSignedIPA(",
        "private func bridgedInstallProgress("
    )
    # 两个安装分支必须对称地走同一个包装：Seal 自替换漏了会丢掉「回主页」信号，
    # 普通安装漏了则从上传完成到装完整段停在「传输中」。
    check(install_signed_body.count("bridgedInstallProgress(") >= 2,
          "R10: both install branches must bridge the upload sentinel (batch callbacks see stages only)")
    check("isSelfReplacement: false" in install_signed_body
          and "bridgedInstallProgress(" in install_signed_body.split("isSelfReplacement: false", 1)[1],
          "R10: the ordinary-app install path is the one that used to stall on '传输中'")
    bridge_helper = section(
        load("Seal/Core/Signing/SigningCoordinator.swift"),
        "private func bridgedInstallProgress(",
        "private func removeStaleProfiles("
    )
    check("InstallStageBridge.shouldEmitInstalling(" in bridge_helper
          and "await progress(.installing)" in bridge_helper,
          "R10: the bridge must actually emit .installing, not just forward the percentage")
    renewal_process = section(
        load("Seal/Core/Renewal/RenewalCoordinator.swift"),
        "private func process(",
        "static let requiresActionCode"
    )
    check("broadcastsInstallStage: true" in renewal_process,
          "R10: batch renewal must ask for the install-stage broadcast")
    check("onInstallProgress: { installProgress in" in renewal_process,
          "R10: batch renewal must subscribe to the upload percentage")
    check(".appInstallProgress(" in renewal_process,
          "R10: batch renewal must forward the real upload percentage to the drawer")
    batch_view = strip_comments(load("Seal/Features/Apps/BatchRefreshView.swift"))
    check("InstallWaitNote(startedAt:" in batch_view,
          "R10: the batch drawer must explain the install wait instead of standing still")
    check("currentInstallProgress" in batch_view,
          "R10: the batch drawer must show the real upload percentage")
    check("cancelBatchRefresh()" in batch_view,
          "R10: a running batch must expose a cancel path")
    progress_view = strip_comments(load("Seal/Features/Apps/SigningProgressView.swift"))
    check("InstallWaitNote(startedAt: session?.installStartedAt)" in progress_view,
          "R10: the single-signing sheet must explain the 93% install wait")
    check("cancelSigning()" in progress_view,
          "R10: a running signing session must expose a cancel path")
    # 运行中隐藏 footer + 禁用下滑关闭 = 弹窗内没有任何操作，用户被锁死。
    check("showsFooter: !isRunning" not in batch_view
          and "showsFooter: !isRunning" not in progress_view,
          "R10: hiding the footer while running removes the only way out of a stuck run")
    # Seal 自续签的「回主页」是 93% 的唯一出口：iOS 只有在旧进程让出前台后才完成替换。
    progress_raw = load("Seal/Features/Apps/SigningProgressView.swift")
    # 前台状态 → 动作的映射必须留在**纯函数**里：这段判断原先直接读
    # `UIApplication.shared.applicationState` 并就地 return，没有任何测试覆盖，
    # 而它的 `.inactive` 分支正是「Seal 自续签永久停在 93%」的根因（2026-09-16 真机反馈）。
    check("enum ReturnHomeStep" in progress_raw
          and "static func step(for state: UIApplication.State) -> ReturnHomeStep" in progress_raw,
          "R10: the foreground-state decision must stay a testable pure function")
    step_body = squash(strip_comments(section(
        progress_raw,
        "static func step(for state: UIApplication.State) -> ReturnHomeStep",
        "@MainActor"
    )))
    # `.inactive` 是瞬时失焦（控制中心/通知横幅/来电/App 切换器预览/系统弹窗），进程仍在前台。
    # 旧实现把它当成「用户已离开」直接 return，连 exit(0) 兜底一起跳过 ——
    # iOS 永远等不到旧进程让出前台，界面永久停在 93%（2026-09-16 真机反馈）。
    check("case .inactive: return .waitForForeground" in step_body,
          "R10: .inactive is a transient blur — returning early strands the install at 93%")
    check("case .background: return .standDown" in step_body,
          "R10: only a real background transition means the user left")
    check("@unknown default: return .waitForForeground" in step_body,
          "R10: an unknown foreground state must wait, not give up")
    return_home = squash(strip_comments(section(
        progress_raw,
        "static func returnToHomeAfterSealUpload(logStore: SealLogStore? = nil)",
        "private static func triggerHomeTransition"
    )))
    # 结构还在不等于还在用：等待循环必须真的走 step()/poll()，否则守卫守的是没人调的函数。
    #
    # 局部变量刻意叫 `currentStep`：写成 `let step = step(for:)` 会让右侧解析到尚未
    # 初始化的局部变量，直接编译失败（`use of local variable 'step' before its declaration`）。
    check("let currentStep = step(for: app.applicationState)" in return_home
          and "poll(" in return_home,
          "R10: the wait loop must route through the tested step/poll functions")
    check('await log(logStore, "Seal 自替换：当前为瞬时失焦，等待回到前台")' in return_home
          and "try? await Task.sleep(nanoseconds: inactiveRetryNanoseconds)" in return_home,
          "R10: .inactive must actually be waited out, not merely skipped")
    # `.standDown`（用户切走了）**绝不能再「立即放弃」** —— 这是 2026-09-16 真机
    # 「续签卡在 93%」的直接原因。
    #
    # 旧实现的语义是「用户已切走了，进程已让出前台，iOS 会自己完成替换 ⇒ 返回 false、
    # 不强杀进程」。这个前提对**覆盖安装运行中的自己**不成立：iOS 需要旧进程**终止**，
    # 而后台进程不会自己终止（自续签还主动开了后台保活）。两份真机日志
    #（`Seal-log(7).txt` / `Seal-log(8).txt`）里，两次自续签都停在 93%，而进程
    # **既不转场也不退出**、照常写后台日志 —— 若 suspend 生效进程会被冻结、若 exit(0)
    # 执行进程会终止，两者都没发生，只剩「这条分支把动作丢掉了」一种解释。
    #
    # 现在断言的是**语义**：这个分支既要「等」（guard outcome == .wait + 真的 sleep），
    # 又必须在超时后 `return` 出去走 `exit(0)` 兜底。用 `section()` 切分支，不拼整句文案 ——
    # 分支里插一条日志就会让拼接式断言失效，而那种失败看着像「语义坏了」。
    #
    # ⚠️ 刻意**不**断言 `"exit(0)" in stand_down`：这段的日志文案里正好含「强制 exit(0)」
    # 字样，那是文本巧合，不是控制流。删掉真正的 `return` 时它照样通过（绿着坏掉）。
    stand_down = section(return_home, "case .standDown:", "case .waitForForeground:")
    check("guard outcome == .wait else" in stand_down
          and "return }" in stand_down
          and "try? await Task.sleep(nanoseconds: backgroundPollNanoseconds)" in stand_down,
          "R10: .standDown must wait for the user to come back, then force exit — "
          "giving up here strands the install at 93%")
    check("exit(0)" in return_home,
          "R10: the exit fallback must stay reachable on every path")
    # 轮询预算本身必须是**有界**的：无限等只是另一种形式的永久卡住。
    # `poll` 是纯函数（有单测），这里守它的形状，防止有人把某个分支改成永远 `.wait`。
    poll_body = squash(strip_comments(section(
        progress_raw,
        "static func poll(",
        "static func returnToHomeAfterSealUpload"
    )))
    check("case .triggerTransition: return .act" in poll_body,
          "R10: an active foreground must trigger the transition immediately")
    check("case .waitForForeground: return rounds < inactiveRetryLimit ? .wait : .act" in poll_body,
          "R10: the transient-blur wait must be bounded by rounds")
    check("case .standDown: return waited < backgroundWaitSeconds ? .wait : .act" in poll_body,
          "R10: the background wait must be bounded — waiting forever is another kind of freeze")
    # 预算值也要钉住：改成 0 会让转场来不及触发，改成极大等于「永远等」。
    check("private static let backgroundWaitSeconds: TimeInterval = 8" in progress_raw,
          "R10: the background wait budget must stay a concrete, small value")
    # 单测必须真的覆盖这些边界 —— 否则「测试被删空」后守卫仍然全绿。
    background_tests = load("SealTests/Apps/SelfInstallAutoBackgroundTests.swift")
    check("SelfInstallAutoBackground.poll(for: .standDown, waited: 0, rounds: 0) == .wait"
          in background_tests
          and "func everyStateEventuallyActs()" in background_tests,
          "R10: the poll boundaries must stay covered by unit tests")
    # 「回主屏」这条链路必须留下日志，而且**挂起前那条必须先落盘**。
    #
    # 2026-09-16 真机：自替换卡在 93% 时这条链路一行日志都没有，于是「转场到底有没有
    # 触发、是在 installation_proxy 返回之前还是之后触发」只能靠猜。加日志是为了让它
    # **可观测**：`安装 开始自替换安装：…` → 心跳 → `Seal 自替换：触发回主屏转场（suspend）`
    # → `安装 自替换安装调用已返回：…`。
    #
    # `suspend` 一旦生效进程即被冻结，所以「触发转场」这条**必须写在 `triggerHomeTransition`
    # 之前**，且每条都 `flush()`：顺序反了、或只 append 不 flush，下次真机排查又会退回
    # 「一片空白」—— 那正是这条缺陷最难查的地方。
    check("await store.append(category: .installation" in progress_raw
          and "await store.flush()" in progress_raw,
          "R10: the return-home path must log — silence is why the freeze was undiagnosable")
    # 断言「顺序」而不是「文案」：日志措辞可以改，但必须先落盘再挂起。
    transition_branch = section(return_home, "case .triggerTransition:", "case .standDown:")
    check("await log(logStore," in transition_branch
          and transition_branch.index("await log(logStore,")
          < transition_branch.index("triggerHomeTransition(app)"),
          "R10: the suspend log must be flushed before the process is frozen")
    # 「回主页」的触发点必须在**状态层**，不能挂在界面上。
    # 抽屉现在有「取消」按钮（软取消：立即关界面，已下发的安装由 installd 跑完），
    # 用户一旦在 Seal 安装期间点取消，SigningProgressView 就没了 ——
    # 挂在它 `.onChange` 上的触发点收不到后续阶段推进，「回主页」永远不会发生，
    # Seal 的替换**静默失败**（旧版本继续跑，用户以为更新没生效）。
    # 批量续签那条链路本来就在状态层触发（见 consumeBatchEvent），单签与它对齐。
    apps_view = squash(strip_comments(load("Seal/Features/Apps/AppsViewModel.swift")))
    check("if stage == .installing, tick == .restart, signingSession?.app.isSeal == true {"
          in apps_view,
          "R10: single signing must trigger the return-home from the state layer, once")
    # 两条链路（单签 + 批量）都必须把**真实的**日志出口交下去：
    # 只声明依赖、调用点传 nil，等于这条链路重新变回静默（下次真机又查不出卡在哪）。
    check(apps_view.count(
              "SelfInstallAutoBackground.returnToHomeAfterSealUpload(logStore: logStore)") == 2,
          "R10: both signing paths must trigger the return-home with a real log outlet")
    # 批量链路的「回主页」也必须带 `.restart` 闸门。`.installing` 会被重复推送
    #（安装通道的 >1.0 哨兵 + 签名侧补发），不设闸门就会排出多个任务 ——
    # 这种重复本身是良性的（第一个任务转场后进程被挂起，后续任务不执行），但**每个任务
    # 都会写一遍「上传完成 / 触发转场」日志**，把真机排查最关键的那段时序信息淹没。
    # 单签那条链路本来就有这个闸门，这里与它对齐。
    check("if stage == .installing, tick == .restart {" in apps_view,
          "R10: a repeated .installing push must not spawn a second return-home")
    # 界面自己再触发一次 = 双重「回主页」（两个系统转场 + 两个 exit(0) 兜底）。
    check("SelfInstallAutoBackground.returnToHomeAfterSealUpload" not in progress_view,
          "R10: the view must not trigger the return-home — it can be dismissed mid-install")
    # 源码断言守的是「形状」，单测守的是「行为」。`.inactive` 这条分支必须真的有单测 ——
    # 否则重构可以改掉它的返回值而守卫只看见「函数还在」（本轮把这段抽成纯函数就是为了它）。
    auto_bg_tests = load("SealTests/Apps/SelfInstallAutoBackgroundTests.swift")
    check("SelfInstallAutoBackground.step(for: .inactive) == .waitForForeground" in auto_bg_tests,
          "R10: the .inactive branch needs a real unit test, not only a source assertion")

    # R10: 安装阶段的计时起点规则（单签 / 批量）只能有一份。
    # 两处各抄一遍的漂移不会编译失败、不会跑挂单测，只会让其中一条链路的
    # 「已等待 m:ss」变成假象（永远 0:00，或带上上一项的等待时间）。
    timeline_source = strip_comments(load("Seal/Core/Signing/InstallStageTimeline.swift"))
    check("currentStage == .installing ? .keep : .restart" in timeline_source,
          "R10: repeated .installing pushes must not reset the install clock")
    for timeline_user in ("Seal/Features/Apps/AppsViewModel.swift",
                          "Seal/Core/Renewal/BatchRefreshSession.swift"):
        check("InstallStageTimeline.tick(" in strip_comments(load(timeline_user)),
              "R10: " + timeline_user + " must use the shared install-start rule")
    timeline_tests = load("SealTests/Signing/InstallStageTimelineTests.swift")
    check("InstallStageTimeline.tick(entering: .installing, currentStage: .installing) == .keep"
          in timeline_tests,
          "R10: the shared install-start rule needs a real unit test")

    # R10: 自替换安装（Seal 覆盖运行中的自己）不能「永久停在 93%」。
    #
    # 2026-09-16 真机日志给出的对照（Seal-log(7)）：
    #   16:59:06 开始安装 LiveContainer → 16:59:13「签名并安装成功」   = 7 秒
    #   16:53:57 签名产物核验通过（Seal 自替换）→ 93 秒后仍无任何安装结论，
    #            进程还活着、还在打其它后台日志，Seal 也从未被替换
    # 而旧实现的这段是裸的 `try await installation.value`：没有超时、没有日志，
    # 所以卡住时既不会结束、也查不出卡在哪。
    #
    # 这些约束改回旧写法**不会编译失败、也不会跑挂单测**，只会让真机重新永久卡住。
    #
    # 1) 自替换的等待必须带超时，且超时**只停止等待、绝不取消**底层同步 FFI：
    #    `offThread` 的默认 `cancelsWorkOnTimeout: true` 会把取消传给 Rust 侧，
    #    可能撤销已下发的 installation_proxy 命令 —— 把「可能还在装」变成「确定装不上」。
    self_replace = strip_comments(load("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift"))
    check("cancelsWorkOnTimeout: false" in self_replace,
          "R10: the self-replacement wait must stop waiting without cancelling the FFI")
    # 2) 等待只允许有一处：在别处再裸等一遍 `installation.value` 等于重新引入无超时等待。
    check(self_replace.count("try await installation.value") == 1,
          "R10: installation.value may only be awaited inside the watchdog")
    check(self_replace.count("Task.detached(priority: .userInitiated)") == 1,
          "R10: the install task must be created in exactly one place (the watchdog)")
    check(self_replace.count("runSelfReplacementInstall(") == 3,
          "R10: both self-replacement branches must go through the guarded install")
    # 3) 自替换必须单飞：真机日志里 91 秒内提交了两笔，而第一笔从未返回。
    check("guard selfReplacementGate.acquire() else {" in self_replace,
          "R10: a second concurrent self-replacement install must be refused")
    check("selfReplacementGate.release(timedOut: Self.isTimeoutInstallError(error))"
          in self_replace,
          "R10: a timeout must keep the self-replacement gate closed (the FFI is still running)")
    # 4) 安装链路必须留下日志：卡住时「一片空白」本身就是最大的障碍。
    check("logStore: SealLogStore?" in self_replace
          and "await logStore.append(" in self_replace,
          "R10: the install path must log — silence is why the freeze was undiagnosable")
    check('await log("开始自替换安装：' in self_replace
          and 'await log("自替换安装调用已返回：' in self_replace,
          "R10: a self-replacement install must log both start and return")
    # 心跳必须是**共用实现**，两条路径都走它。
    # 2026-09-17 真机（构建 97）：普通安装卡了 9 分多钟，日志里从「开始安装」到
    # 用户导出日志**一行都没有** —— 因为当时心跳只加在自替换这条路径上，
    # 而这条断言也只钉住了那条路径，所以它一直是绿的（R14 补上了双路径）。
    check("private func beginInstallHeartbeat(" in self_replace
          and 'beginInstallHeartbeat("自替换安装")' in self_replace
          and "仍在等待：已等待" in self_replace,
          "R10: the install wait needs a heartbeat — installd reports no progress")
    # 5) 只声明可选依赖、容器不传 = 永远静默。
    #    必须限定在 installChannel 的构造段里：`logStore: logStore` 在同一个文件里
    #    也出现在 SigningCoordinator 的构造处，全局匹配会让「只改安装通道这一处」
    #    的变异检不出来（本轮实际踩到）。
    container_source = strip_comments(load("Seal/Application/AppContainer.swift"))
    channel_init = section(
        container_source,
        "let installChannel = MinimuxerInstallChannel(",
        "let operationCoordinator"
    )
    check("logStore: logStore" in channel_init,
          "R10: AppContainer must hand the install channel a real log store")
    # 6) 源码断言守「形状」，单测守「行为」：这两条新规则都容易写反，必须有单测。
    gate_tests = load("SealTests/Installation/SelfReplacementInstallGateTests.swift")
    check("func timeoutKeepsTheGateClosed()" in gate_tests,
          "R10: 'a timeout must not reopen the gate' needs a real unit test")
    hard_timeout_tests = load("SealTests/Concurrency/HardTimeoutTests.swift")
    check("func nonCancellingTimeoutLeavesTheWorkRunning()" in hard_timeout_tests,
          "R10: 'stop waiting without cancelling' needs a real unit test")

    # 模拟器切片缺符号（2026-09-16，同一类错误一天内咬了两次）。
    #
    # 症状最坑的地方是**两片 CI 一绿一红**：`build-package` 只编设备切片，永远绿；
    # 只有 `swift-regression`（模拟器切片）会红，而一轮 CI 要 13–16 分钟。第一次是
    # `diagnostic`、第二次是 `isTimeoutInstallError` —— 都是同一个形状：
    # 「定义在 `#if !targetEnvironment(simulator)` 里，却被 `#if` 之外的代码引用」。
    #
    # 检查方式：把「模拟器切片不编译」的行整段抹成空白，再看有没有**只**出现在被抹掉
    # 那部分里的顶层类型成员，出现在抹后文本中 —— 出现了，就是模拟器代码引用了它。
    simulator_leaks = []
    for source_path in swift_sources():
        relative = source_path.relative_to(ROOT).as_posix()
        # 先在**未去注释**的原文上做一次廉价子串判断再决定是否去注释：这个循环要
        # 跑遍 200+ 个文件、而守卫总共要把 `violations()` 跑 90 多遍，全仓只有个别
        # 文件与目标平台条件编译有关，没必要为其余文件付出去注释的代价。
        if "targetEnvironment" not in load_cached(relative):
            continue
        source = strip_cached(relative)
        kept, blanked = mask_inactive_on_simulator(source)
        if not blanked:
            continue
        kept_definitions = set(_SIMULATOR_MEMBER.findall(kept))
        lines = source.splitlines(keepends=True)
        # 重建「只保留设备专属行」的文本：非设备专属行换成等量换行，行号不变，
        # 这样 `^    ` 的锚定与真实文件一致。
        device_only = "".join(
            lines[index - 1] if index in blanked else "\n" * lines[index - 1].count("\n")
            for index in range(1, len(lines) + 1)
        )
        for match in _SIMULATOR_MEMBER.finditer(device_only):
            name = match.group(1)
            # 两片各留一份定义（模拟器桩）是合法写法，不算缺符号。
            if name in kept_definitions:
                continue
            if re.search(r"\b" + re.escape(name) + r"\b", kept):
                simulator_leaks.append(relative + " -> " + name)
    check(not simulator_leaks,
          "Simulator: device-only members must not be referenced by simulator code ("
          + " | ".join(simulator_leaks) + ")")

    # `#expect(...)` 里不能出现 mutating 方法调用（2026-09-16，紧随上一条之后踩到）。
    #
    # swift-testing 的 `#expect` 是**宏**：它把表达式重写成闭包、把子表达式绑成
    # `$0`/`$1`…，于是 mutating 成员作用在捕获值上编译不过 ——
    # `error: cannot use mutating member on immutable value: '$0' is immutable`。
    # 修法是把调用提到 `#expect` 外面（`let ok = gate.acquire(); #expect(ok)`）。
    #
    # 与上一条同样的坑：**这个错误只在 `swift-regression` 出现**（`build-package`
    # 不编译测试 target），一轮 CI 白等 13 分钟。所以必须由守卫拦。
    #
    # mutating 方法名从 `Seal/` 里现取，不写死：全仓只有个位数（`acquire` / `release` /
    # `advanceStage` / `recordInstallProgress` / 证书材料那几个），名字都很独特，
    # 按「`.名字(`」匹配不会误伤。
    mutating_names = set()
    for source_path in swift_sources():
        relative = source_path.relative_to(ROOT).as_posix()
        if not relative.startswith("Seal/"):
            continue
        if "mutating" not in load_cached(relative):
            continue
        mutating_names.update(
            re.findall(r"mutating\s+func\s+([A-Za-z_][A-Za-z0-9_]*)", strip_cached(relative))
        )
    check(len(mutating_names) >= 5,
          "Testing: mutating-member scan found too few names — the pattern drifted")
    mutating_call = re.compile(
        r"\.(?:" + "|".join(re.escape(name) for name in sorted(mutating_names)) + r")\s*\("
    ) if mutating_names else None
    expect_mutations = []
    for source_path in swift_sources():
        relative = source_path.relative_to(ROOT).as_posix()
        if not relative.startswith("SealTests/"):
            continue
        # 先看原文里有没有「#expect(」+ 某个 mutating 调用，再决定是否去注释。
        raw = load_cached(relative)
        if "#expect(" not in raw or mutating_call is None or mutating_call.search(raw) is None:
            continue
        source = strip_cached(relative)
        for match in re.finditer(r"#expect\(", source):
            close = match_paren(source, match.end() - 1)
            if close == -1:
                continue
            inner = source[match.end():close]
            for name in sorted(mutating_names):
                if re.search(r"\." + re.escape(name) + r"\s*\(", inner):
                    expect_mutations.append(relative + " -> " + name)
    check(not expect_mutations,
          "#expect must not call a mutating method — it is rewritten into a closure ("
          + " | ".join(expect_mutations) + ")")

    # `?? []` 的类型推断陷阱（2026-09-17 因此挂了一轮 CI，同样只在 `swift-regression` 暴露）。
    #
    # `Dictionary.Keys` / `Dictionary.Values` **不是** `ExpressibleByArrayLiteral`，
    # 所以 `dict.first?.keys ?? []` 里的 `[]` 无法被推断成那个类型，Swift 退化成 `[Any]`：
    #   error: cannot convert value of type '[Any]' to expected argument type
    #          'Dictionary<String, String>.Keys'
    # 正确写法：先 `guard let` 取出字典再 `Set(dict.keys)`，或用 `.map { $0 }` 显式转成数组。
    #
    # 判据（值得记住的通用形式）：**`??` 的右侧用字面量兜底时，左侧必须是可以从该字面量
    # 构造出来的类型**（`Array` / `Set` / `Dictionary` 可以，`Keys` / `Values` / 其它
    # `Collection` 不行）。
    keys_fallback_pattern = re.compile(r"\.(?:keys|values)\s*\?\?\s*\[\]")
    keys_fallback = []
    for source_path in swift_sources():
        relative = source_path.relative_to(ROOT).as_posix()
        if not (relative.startswith("Seal/") or relative.startswith("SealTests/")):
            continue
        # 廉价预筛用「坏形状」本身，不要用 `"??" in raw` —— 几乎每个 Swift 文件都含 `??`，
        # 那样每个变异遍都会去注释 200+ 文件，整轮守卫耗时翻倍（本轮实测过一次）。
        if keys_fallback_pattern.search(load_cached(relative)) is None:
            continue
        # 命中的还要确认**不在注释里**：注释里写反面示例是允许的，本轮就写了。
        for line_number, line in enumerate(strip_cached(relative).splitlines(), start=1):
            if keys_fallback_pattern.search(line):
                keys_fallback.append(f"{relative}:{line_number}")
    check(not keys_fallback,
          "`?? []` after .keys/.values cannot type-check — Dictionary.Keys is not "
          "ExpressibleByArrayLiteral, so `[]` degrades to [Any] ("
          + " | ".join(keys_fallback) + ")")

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
    # 现在有**两处**删除步骤（孤儿文件清理、设备端旧描述文件清理），各自都要有租约复查。
    # 只写 `in job` 的话，删掉其中一处仍会被另一处掩盖 —— 守卫会变成「永远全绿」。
    check(job.count("guard gate.shouldAbort(token) == false else") >= 2,
          "C: the sweep must re-check the lease before deleting anything")
    check(job.count("gate.shouldAbort(token)") >= 4,
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
    install_channel_code = strip_comments(install_channel)
    # 重试循环现在**只有一份**：无进度重载已改为转发到带进度的实现。
    # 曾经是两份，规则各写一遍 —— 那正是「修了一个、漏了另一个」的来源。
    check(install_channel_code.count("if Self.isTimeoutInstallError(error) {") == 1,
          "B: the single install retry loop must treat timeout as terminal")
    # 被自替换闸门拒绝同样必须按终态处理：重试只会被同一个闸门再拒一次，
    # 而两条重试路径里的 Minimuxer.reset() / Install.resetProvider() 会把
    # **可能仍在跑的安装连接**拆掉 —— 那比不重试更糟。
    check(install_channel_code.count("if Self.isSelfReplacementBusyError(error) {") == 2,
          "B: both retry paths must treat a refused self-replacement as terminal")
    check("onProgress: { _ in }" in install_channel_code,
          "B: the no-progress install overload must delegate, not keep a second copy")
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
    # 基准内容缓存：见下面变异循环处的说明。整轮里源文件不会变，只有被替换的那个
    # 走闭包里的 `changed`，所以这个缓存不会让变异检查读到陈旧文本。
    base_cache = {}

    def base_read(path):
        if path not in base_cache:
            base_cache[path] = read(path)
        return base_cache[path]

    count, failures = violations(base_read)
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
         "B: the single install retry loop must treat timeout as terminal"),
        # 去掉「被闸门拒绝 = 终态」：重试会 reset 掉可能仍在跑的安装连接，
        # 把第一笔安装彻底弄坏（比不重试更糟）。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "                if Self.isSelfReplacementBusyError(error) {\n                    throw error\n                }\n",
         "",
         "B: both retry paths must treat a refused self-replacement as terminal"),
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
        ("Seal/Features/Apps/SigningProgressView.swift",
         "        UIControl().sendAction(selector, to: app, for: nil)\n    }",
         "        return UIControl().sendAction(selector, to: app, for: nil)\n    }",
         "R07: UIControl.sendAction returns Void"),
        ("Seal/Infrastructure/Installation/SignedArtifactProfileReader.swift",
         "for entry in archive where isInstalledAppProvision(entry.path) {",
         "for entry in archive where isMainProvision(entry.path) {",
         "R08: cleanup must know every installed profile"),
        ("Seal/Infrastructure/Installation/SignedArtifactProfileReader.swift",
         'return container.hasSuffix(".app") || container.hasSuffix(".appex")',
         'return container.hasSuffix(".app")',
         "R08: extensions are .appex"),
        # 把 keep-map 命中改成「恒真 + keeping 为空」⇒ 每个 profile 的 UUID 都 ≠ ""，
        # 于是**全部**被当成旧份删掉，包括正在用的那一份（App 立刻起不来）。
        # 2026-09-17 重构成两段式后锚点跟着改：原来那行 `guard let keepingUUID = ...` 已不存在。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "            if let keepingUUID = keepingByBundleID[loweredBundleID] {",
         "            let keepingUUID = keepingByBundleID[loweredBundleID] ?? \"\"\n            if true {",
         "R08: a profile may only be deleted after its managed bundle-id lookup succeeded"),
        # 把 dump 重试次数改回 1：撞上瞬时 NoDevice 就整轮白丢 —— 原样重演 2026-09-16 真机
        # 的 `扫描 0，匹配 0，删除 0，中断于 dump`，而 profile 在此期间继续累积。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "    private static let dumpAttemptLimit = 3",
         "    private static let dumpAttemptLimit = 1",
         "R08: a transient NoDevice must not throw away the whole cleanup round"),
        # 重试前不重置 provider：三条重试全走同一条已经断开的 RSD 连接，等于没重试
        #（循环还在、次数还在，约束已经失效）。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "                Provision.resetProvider()\n"
         "                try? await Task.sleep(nanoseconds: dumpRetryDelayNanoseconds)",
         "                try? await Task.sleep(nanoseconds: dumpRetryDelayNanoseconds)",
         "R08: retrying the dump without resetting the cached provider retries the same dead link"),
        # 绕过带重试的包装、直接调 FFI：重试形同虚设，函数与单测都还在。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "dump = try await dumpProfiles(docsPath: workingDir.path)",
         "dump = (path: try Provision.dumpProfiles(docsPath: workingDir.path), attempts: 1)",
         "R08: the sweep must go through the retrying dump wrapper"),
        # `.skipped` 退回「只有一句 break」：用户看到 profile 一直在堆，
        # 却查不出「这一轮到底跑没跑」—— 真机排查直接断线。
        ("Seal/Features/Apps/AppsViewModel.swift",
         "            try? await logStore?.append(\n"
         "                category: .system,\n"
         '                message: "维护作业本轮跳过：有前台操作正在进行（下次启动或空闲时再试）",\n'
         '                code: "SEAL-STORAGE-009"\n'
         "            )\n"
         "        case .completed",
         "            break\n"
         "        case .completed",
         "R08: every non-.completed maintenance outcome must leave a trace"),
        # `.failed` 退回「只弹窗不写日志」：用户划掉弹窗后日志里什么都没留下，
        # 事后完全查不出是哪一步失败。
        ("Seal/Features/Apps/AppsViewModel.swift",
         "            try? await logStore?.append(\n"
         "                category: .system,\n"
         "                level: .warning,\n"
         '                message: "维护作业失败：\\(failure.title)（\\(failure.code)）",\n'
         '                code: "SEAL-STORAGE-010"\n'
         "            )\n"
         "            alertFailure = failure",
         "            alertFailure = failure",
         "R08: every non-.completed maintenance outcome must leave a trace"),
        # 自替换结算清理退回「只写事务审计、不写日志」：排障时拿到的日志里永远看不到
        # Seal 自己的旧 profile 有没有被回收，16 份堆积看起来像清理逻辑根本不存在。
        ("Seal/Core/Renewal/SelfAppRegistrar.swift",
         "            try? await logStore?.append(\n"
         "                category: .installation,\n"
         '                message: "自替换结算清理：\\(cleanup.logMessage)",\n'
         '                code: "SEAL-PROFILE-322"\n'
         "            )\n"
         "            try await selfReplacement.finishCleanup(cleanup)",
         "            try await selfReplacement.finishCleanup(cleanup)",
         "R08: the self-replacement cleanup must log before closing the transaction"),
        # 把单测里的关键判定改宽（`hasPrefix("自")` 什么都通过）：
        # 「单测文件里有这几行」这类断言必须真的会红，否则测试被改宽后守卫照样绿。
        ("SealTests/Renewal/SelfAppPendingHandoffTests.swift",
         '$0.message.hasPrefix("自替换结算清理：")',
         '$0.message.hasPrefix("自")',
         "R08: the self-replacement cleanup log needs a real unit test"),
        # 把重试次数的单测改回「只试一次」：断言「单测覆盖了重试」的那条必须真的会红。
        ("SealTests/Installation/DeviceProfileCleanerTests.swift",
         "dumpAttempts: 3",
         "dumpAttempts: 1",
         "R08: the retry count must stay covered by a real unit test"),
        # 导出时不透传构建标识：表头还在，但「这份日志来自哪个构建」重新变成靠猜 ——
        # 正是 2026-09-17 那轮白跑的成因。
        ("Seal/Infrastructure/Diagnostics/SealLogStore.swift",
         "            notice: notice,\n"
         "            buildLabel: SealLogTextFormatter.currentBuildLabel\n"
         "        )",
         "            notice: notice\n"
         "        )",
         "R08: the store must pass the build label through"),
        # 表头不再渲染构建号（字段还在、属性还在，只是没进文本）。
        ("Seal/Core/Diagnostics/SealLogEntry.swift",
         '"构建 \\(buildLabel)',
         '"构建"',
         "R08: the build label must actually be rendered into the export header"),
        ("Seal/Core/Maintenance/AppMaintenanceJob.swift",
         "guard let uuid = record.provisioningProfileUUID,",
         "let uuid = record.provisioningProfileUUID ?? \"\",",
         "R08: records without a profile UUID must be skipped"),
        ("Seal/Core/Maintenance/AppMaintenanceJob.swift",
         "guard record.signedArtifactStatus == .installed else { continue }",
         "guard true else { continue }",
         "R08: extension profile ids are optimistic"),
        # ── R11: 旧 Team 变体回收的安全边界 ──────────────────────────────────
        # 把「查询失败」当成「没装」：这是最危险的一条 —— 隧道抖动时**所有**候选
        # 都被读成「没装」，于是删掉正在用的 profile，对应 App 立刻无法启动。
        ("Seal/Core/Maintenance/ProfileReclaimPolicy.swift",
         "            return .abortPass\n        case .installed:",
         "            return .notInstalled\n        case .installed:",
         "R11: a failed probe must abort the pass"),
        # 去掉阳性对照：`.reclaim` 变成只要「答未安装」就给，
        # 而「答未安装」恰恰是通道不可信时最容易出现的答案。
        ("Seal/Core/Maintenance/ProfileReclaimPolicy.swift",
         "return positiveControlPassed ? .reclaim : .abortPass",
         "return .reclaim",
         "R11: .reclaim must require a passed positive control"),
        # 用 `lookupApp` 替掉会抛错的 `isAppInstalled`：把「没装」与「查询失败」
        # 折叠成同一个 `nil`，正是上面那条灾难的入口。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "                try Minimuxer.isAppInstalled(bundleId: bundleID)",
         "                Minimuxer.lookupApp(bundleId: bundleID) != nil",
         "R11: the reclaim path must use the throwing isAppInstalled"),
        # 让阳性对照永远通过：对照形同虚设，通道不可信时照样全删。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "let positiveControlPassed = await probeInstalled(bundleID: controlBundleID) == .installed",
         "let positiveControlPassed = true",
         "R11: the positive control must be an actual probe of a definitely-installed app"),
        # 中止改成「只记原因、继续往下删」：后面的候选（以及已经问过的那几条）
        # 继续被一条已经不可信的通道判定并删除 —— 但代码看起来仍然「有中止逻辑」，
        # 是最容易漏掉的一种退化。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "        guard reclaimAbortReason == nil else {\n"
         "            summary.reclaimAborted = reclaimAbortReason\n"
         "            return summary\n"
         "        }",
         "        if reclaimAbortReason != nil {\n"
         "            summary.reclaimAborted = reclaimAbortReason\n"
         "        }",
         "R11: .abortPass must record why and stop the whole pass"),
        # 中止不落日志：`回收 0` 会被读成「形态没匹配上」，而实际是通道不可信 ——
        # 两者的后续动作完全不同（前者要查判据，后者要查设备连接）。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "        if let reclaimAborted {\n",
         "        if false, let reclaimAborted {\n",
         "R11: an aborted reclaim must be visible"),
        # 把 keep-map 命中判断退回「精确查表」：key 大小写不一致时会把「正在用的那个」
        # 判成可回收 ⇒ 删掉活着的 profile。（2026-09-17 真的这样挂过一次 CI。）
        ("Seal/Core/Maintenance/ProfileReclaimPolicy.swift",
         "guard keepingByBundleID.keys.contains(where: { normalized($0) == lowered }) == false else {",
         "guard keepingByBundleID[lowered] == nil else {",
         "R11: the keep-map membership test must be case-insensitive"),
        # 删掉宽松受保护集合那一句：扩展 ID 重新变成候选，而设备端核验对扩展恒答「没装」
        # ⇒ 已装 App 的扩展 profile 被删（2026-09-17 真机事故）。
        ("Seal/Core/Maintenance/ProfileReclaimPolicy.swift",
         "guard protectedBundleIDs.contains(where: { normalized($0) == lowered }) == false else {",
         "guard true else {",
         "R11: the candidate rule needs a separate protected set"),
        # 给宽松集合加回 `.installed` 门槛：与严格 keep-map 变成同一个集合，
        # 标记一陈旧扩展就掉出保护范围 —— 这正是事故的形态。
        ("Seal/Core/Maintenance/ProfileReclaimPolicy.swift",
         "            for extensionRecord in record.extensions {\n"
         "                if let extensionID = effectiveBundleID(",
         "            guard record.signedArtifactStatus == .installed else { continue }\n"
         "            for extensionRecord in record.extensions {\n"
         "                if let extensionID = effectiveBundleID(",
         "R11: the protected set must collect extensions unconditionally"),
        # 调用点漏传受保护集合（传空集）：判据本身没被改，但保护等于没有。
        ("Seal/Core/Maintenance/AppMaintenanceJob.swift",
         "protectedBundleIDs: ProfileReclaimPolicy.protectedBundleIDs(records: records),",
         "protectedBundleIDs: [],",
         "R11: idle maintenance must pass a record-derived protected set"),
        # 结算路径漏传：它的 keep-map 只有 Seal 自己，别的 App 的扩展全靠这个集合。
        ("Seal/Core/Renewal/SelfAppRegistrar.swift",
         "protectedBundleIDs: ProfileReclaimPolicy.protectedBundleIDs(records: allRecords)",
         "protectedBundleIDs: []",
         "R11: self-replacement settle must pass a record-derived protected set"),
        # 去掉 fail closed：保护范围未知时照样按「现有信息尽量删」办。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "let reclaimEnabled = reclaimSealOrphans && protectedBundleIDs.isEmpty == false",
         "let reclaimEnabled = reclaimSealOrphans",
         "R11: an empty protected set must disable reclaim entirely"),
        # 把那条「混合大小写 key」的单测改成小写：源码断言（实现里写了 lowercased() 比较）
        # 仍然全绿，但测试已经守不住这个行为了。
        ("SealTests/Maintenance/ProfileReclaimPolicyTests.swift",
         "    func currentBundleIdentifierIsNeverACandidate() {\n"
         '        let keep = ["com.kdt.livecontainer.seal.KYRJV2U7WS": "LIVE-UUID"]',
         "    func currentBundleIdentifierIsNeverACandidate() {\n"
         '        let keep = ["com.kdt.livecontainer.seal.kyrjv2u7ws": "LIVE-UUID"]',
         "R11: the keep-map case-insensitivity needs a real unit test with a mixed-case key"),
        # 把决策分支的单测删掉：源码断言证明不了「每个分支真的被测过」。
        ("SealTests/Maintenance/ProfileReclaimPolicyTests.swift",
         "    func unavailableNeverReclaims() {",
         "    func unavailableNeverReclaimsRenamed() {",
         "R11: every branch of the reclaim decision needs a real unit test"),
        # 维护作业不再开启孤儿回收：编译不失败、别的单测也不红，
        # 只是「换 Apple ID 后旧 Team 后缀的 profile」永远清不掉 —— 正是用户报的现象。
        ("Seal/Core/Maintenance/AppMaintenanceJob.swift",
         "reclaimSealOrphans: true",
         "reclaimSealOrphans: false",
         "R11: idle maintenance must opt in explicitly"),
        # 把「调用方真的开了回收」这条单测改名：证明「单测文件里有这几个字」的断言真的会红。
        ("SealTests/Maintenance/AppMaintenanceJobTests.swift",
         "    func maintenanceSweepEnablesSealOrphanReclaim() async throws {",
         "    func maintenanceSweepEnablesSealOrphanReclaimRenamed() async throws {",
         "R11: the opt-in flag must stay covered by a real unit test"),
        # ── R12：批量续签的逐项成功日志（2026-09-17 真机反馈）──
        # 删掉逐项成功日志：批量路径重新变成「日志里没有结论」，
        # 用户无法判断「某个 App 到底成没成、描述文件是不是新申请的」。
        ("Seal/Core/Renewal/RenewalCoordinator.swift",
         '                    code: "SEAL-RENEW-020"',
         '                    code: "SEAL-RENEW-020-REMOVED"',
         "R12: the batch renewal path must log a per-item success line"),
        # 日志还在，但不再带描述文件身份：看起来「有留痕」，
        # 实际回答不了那个真正的问题（换的是新申请的那份，还是旧的那份）。
        ("Seal/Core/Renewal/RenewalCoordinator.swift",
         "描述文件 \\(Self.describeProfile(updated))",
         "描述文件已更新",
         "R12: the batch renewal path must log a per-item success line"),
        # 描述文件身份里丢掉到期时间：UUID 与创建时间都在，唯独少了「还能用多久」。
        ("Seal/Core/Renewal/RenewalCoordinator.swift",
         "let expires = record.provisioningProfileExpirationDate",
         "let expires: Date? = nil",
         "R12: the per-item success line must carry the profile identity"),
        # 把 ISO8601 换成本地化格式：导出日志的人可能不在中文环境里，
        # 而且没法直接和 Apple 门户返回的时间对照。
        ("Seal/Core/Renewal/RenewalCoordinator.swift",
         "let formatter = ISO8601DateFormatter()",
         "let formatter = DateFormatter()",
         "R12: the per-item success line must carry the profile identity"),
        # 构造点漏传日志库：编译不失败，只是这条日志重新变空白。
        ("Seal/Application/AppContainer.swift",
         "                logStore: logStore\n            )\n            let appRecordRecovery = AppRecordRecovery(",
         "                logStore: nil\n            )\n            let appRecordRecovery = AppRecordRecovery(",
         "R12: the batch coordinator must be given a log store"),
        # 把那条 ISO8601 单测改宽成单字符断言：源码断言仍然全绿，
        # 但测试已经守不住「时间真的是 ISO8601」了（单字符会同时匹配 Character 重载）。
        ("SealTests/Renewal/RenewalCoordinatorLogTests.swift",
         '        #expect(text.contains("2026-09-17T05:28:58Z"))',
         '        #expect(text.contains("T"))',
         "R12: the ISO8601 unit test must assert the full form"),
        # ── R12：轮询日志降噪（2026-09-17 真机日志量化：30% 是噪音）──
        # 把「有待恢复数据才留痕」改回无条件留痕：`load()` 每 9 秒一次，
        # 立刻回到「三成日志是噪音、真实信号被挤出环形缓冲」的状态。
        ("Seal/Features/Apps/AppsViewModel.swift",
         "            if pendingPayload != nil {\n",
         "            if true {\n",
         "R12: the restore poll path must stay silent on the normal path"),
        # 重新引入临时脚手架：证明「[BatchDebug] 已清干净」这条 not-in 断言真的会红。
        ("Seal/Features/Apps/AppsViewModel.swift",
         "        let pendingPayload = loadPendingBatchResultPayload()",
         "        let pendingPayload = loadPendingBatchResultPayload()\n        Task { try? await logStore?.append(category: .renewal, level: .info, message: \"[BatchDebug] restore poll\", code: \"SEAL-BATCH-DEBUG-9\") }",
         "R12: the temporary [BatchDebug] scaffolding must stay removed"),
        # ── R13：「Apple 要求双重认证」的专门分类与提示（2026-09-17 真机取证）──
        # 换掉错误码：Apple 只会用它这个稳定的数字，描述文案会随语言与措辞变。
        ("Seal/Infrastructure/Accounts/AppleAuthenticationDiagnosis.swift",
         "static let twoFactorRequiredCode = 3018",
         "static let twoFactorRequiredCode = 9999",
         "R13: the two-factor error code must stay 3018"),
        # 只按描述判断：文案一改就再也认不出来，而「认不出来」的后果是把用户
        # 引去「核对 Apple ID 与密码」——一个完全正确的密码。
        ("Seal/Infrastructure/Accounts/AppleAuthenticationDiagnosis.swift",
         "if nsError.code == twoFactorRequiredCode { return true }",
         "if false { return true }",
         "R13: the code check must come first"),
        # 只在其中一条链路上做分类（这里删的是 `validate` 那条）：
        # 编译不失败、其它单测也不红，只是那条路径重新给出错误引导。
        ("Seal/Infrastructure/Accounts/AppleAccountClient.swift",
         "            if AppleAuthenticationDiagnosis.isTwoFactorRequired(error) {\n"
         "                throw AppleAuthenticationDiagnosis.twoFactorFailure(for: error)\n"
         "            }\n",
         "",
         "R13: every error-mapping entry point must route"),
        # 分支还在、顺序被换到限流之后：同一个错误在两条路径上给出不同提示。
        # 这是「顺序也是设计」那条断言唯一能抓到它的地方。
        ("Seal/Infrastructure/Accounts/AppleAccountClient.swift",
         "            if AppleAuthenticationDiagnosis.isTwoFactorRequired(error) {\n"
         "                throw AppleAuthenticationDiagnosis.twoFactorFailure(for: error)\n"
         "            }\n"
         "            if AppleServiceFailurePolicy.isRateLimited(error) {\n"
         "                throw AppleServiceFailurePolicy.rateLimitedFailure(underlying: error)\n"
         "            }\n",
         "            if AppleServiceFailurePolicy.isRateLimited(error) {\n"
         "                throw AppleServiceFailurePolicy.rateLimitedFailure(underlying: error)\n"
         "            }\n"
         "            if AppleAuthenticationDiagnosis.isTwoFactorRequired(error) {\n"
         "                throw AppleAuthenticationDiagnosis.twoFactorFailure(for: error)\n"
         "            }\n",
         "R13: AppleAccountClient.validate must check two-factor before"),
        # 分支留着、但自己手写一份泛化提示（`make` 那条）：
        # 看起来「有分支」，实际又回到了「核对 Apple ID 与密码」。
        ("Seal/Infrastructure/Accounts/AppleAccountClient.swift",
         "        if AppleAuthenticationDiagnosis.isTwoFactorRequired(error) {\n"
         "            return AppleAuthenticationDiagnosis.twoFactorFailure(for: error)\n"
         "        }\n",
         '        if AppleAuthenticationDiagnosis.isTwoFactorRequired(error) {\n'
         '            return ImportFailure(title: "无法添加账号", reason: "Apple ID 验证失败。", recovery: "重试；如持续失败请核对 Apple ID 与密码", code: "SEAL-AUTH-107a")\n'
         "        }\n",
         "R13: every entry point must use the shared factory"),
        # 把那条「绝不能叫用户去核对密码」的单测改名：
        # 证明「单测文件里有这几个字」的断言真的会红，而不是永远绿着。
        ("SealTests/Accounts/AppleAuthenticationDiagnosisTests.swift",
         "    func twoFactorFailureNeverTellsTheUserToCheckThePassword() {",
         "    func twoFactorFailureNeverTellsTheUserToCheckThePasswordRenamed() {",
         "R13: the 'never send the user to check the password' rule"),
        # ── R14：安装心跳双路径 + 扩展随父保留（2026-09-17 真机，构建 97）──
        # 只给自替换路径留心跳、普通路径退回静默：真机上普通安装卡住时日志重新一片空白，
        # 「在装」与「死了」再次分不开。这是本轮最直接的成因。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         '                    let heartbeat = beginInstallHeartbeat("安装")',
         "                    // heartbeat removed",
         "R14: BOTH install paths must use the shared heartbeat"),
        # 前缀不在点边界上收口：同一 Team 下的兄弟变体会互相「保护」，回收功能整体失效。
        ("Seal/Core/Maintenance/ProfileReclaimPolicy.swift",
         'if lowered.hasPrefix(parent + ".") { return true }',
         "if lowered.hasPrefix(parent) { return true }",
         "R14: the parent prefix must end on a DOT boundary"),
        # 调用还在、但传空集合：代码看起来「有父 App 判定」，实际一份都不保护 ——
        # 正是真机上丢掉三个扩展 profile 的那条路径。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "                    ofAnyOf: installedCandidates",
         "                    ofAnyOf: []",
         "R14: the pass must consult the parent rule with the real candidate set"),
        # 受保护集合规模不进日志：下次再看到「候选很多」又只能靠推断。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         '            text += "，受保护 \\(protectedCount)"',
         "            // protected count removed",
         "R14: the protected-set size must be in the log"),
        # 把新计数的单测改名：证明「单测文件里有这几个字」的断言真的会红。
        ("SealTests/Installation/DeviceProfileCleanerTests.swift",
         "    func protectedSetSizeIsReported() {",
         "    func protectedSetSizeIsReportedRenamed() {",
         "R14: the new attribution counters need real unit tests"),
        ("SealTests/Maintenance/AppMaintenanceJobTests.swift",
         "            ipaRelativePath: \"Apps/\\(appID.uuidString)/Original.ipa\",\n            signedArtifactStatus: signedArtifactStatus,",
         "            signedArtifactStatus: signedArtifactStatus,\n            ipaRelativePath: \"Apps/\\(appID.uuidString)/Original.ipa\",",
         "R09: AppRecord call-site labels must follow the declaration order"),
        ("Seal/Core/Renewal/RenewalCoordinator.swift",
         "                        selectedCertificateSerialNumber: nil,\n                        forceResign: true,",
         "                        forceResign: true,\n                        selectedCertificateSerialNumber: nil,",
         "R09: signAndInstall call-site labels must follow the declaration order"),
        ("Seal/Core/Signing/InstallStageBridge.swift",
         "uploadProgress > uploadCompletionSentinel",
         "uploadProgress >= uploadCompletionSentinel",
         "R10: 1.0 means 'upload finished', not 'installing'"),
        ("Seal/Core/Signing/SigningCoordinator.swift",
         "                onProgress: bridgedInstallProgress(\n                    broadcastsInstallStage: broadcastsInstallStage,\n                    progress: progress,\n                    onInstallProgress: onInstallProgress\n                )",
         "                onProgress: onInstallProgress",
         "R10: the ordinary-app install path is the one that used to stall"),
        ("Seal/Core/Signing/SigningCoordinator.swift",
         "                await progress(.installing)\n            }\n            await onInstallProgress(installProgress)",
         "                _ = progress\n            }\n            await onInstallProgress(installProgress)",
         "R10: the bridge must actually emit .installing"),
        ("Seal/Core/Renewal/RenewalCoordinator.swift",
         "                        onInstallProgress: { installProgress in",
         "                        onInstallProgressUnused: { installProgress in",
         "R10: batch renewal must subscribe to the upload percentage"),
        # 把新事件「收编」回旧事件：编译通过、事件流还在，但抽屉重新变成没有分母的黑盒。
        ("Seal/Core/Renewal/RenewalCoordinator.swift",
         "                                .appInstallProgress(\n                                    index: offset + 1,\n                                    total: queue.count,\n                                    app: latestApp,\n                                    progress: installProgress\n                                )",
         "                                .appProgress(\n                                    index: offset + 1,\n                                    total: queue.count,\n                                    app: latestApp,\n                                    stage: .pushing\n                                )",
         "R10: batch renewal must forward the real upload percentage"),
        ("Seal/Features/Apps/BatchRefreshView.swift",
         "        SealDrawer(title: drawerTitle, showsFooter: true) {",
         "        SealDrawer(title: drawerTitle, showsFooter: !isRunning) {",
         "R10: hiding the footer while running removes the only way out of a stuck run"),
        ("Seal/Features/Apps/SigningProgressView.swift",
         "        SealDrawer(title: title, showsFooter: true) {",
         "        SealDrawer(title: title, showsFooter: !isRunning) {",
         "R10: hiding the footer while running removes the only way out of a stuck run"),
        # 把 `.inactive` 改回「放弃」= 原样重演 2026-09-16 的「永久停在 93%」。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "        case .inactive:\n            return .waitForForeground",
         "        case .inactive:\n            return .standDown",
         "R10: .inactive is a transient blur"),
        # 把 `.background` 也接上转场：后台状态下 `suspend` 不一定生效（进程本来就不在前台），
        # 而 `.standDown` 这条路径承担的是「等用户回来、等不到就强杀」。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "        case .background:\n            return .standDown",
         "        case .background:\n            return .triggerTransition",
         "R10: only a real background transition means the user left"),
        # `.inactive` 等够 3 秒改成直接放弃等待：控制中心一遮挡就会走到 exit(0)，
        # 在用户还在前台时把进程杀掉，安装永远完不成。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "                inactiveRounds += 1\n"
         '                await log(logStore, "Seal 自替换：当前为瞬时失焦，等待回到前台")\n'
         "                try? await Task.sleep(nanoseconds: inactiveRetryNanoseconds)",
         "                return",
         "R10: .inactive must actually be waited out"),
        # 让 `.standDown` 恢复旧实现那套「立即放弃」：进程既不转场也不退出、永久占着前台，
        # iOS 永远等不到替换时机 —— 这正是 2026-09-16 真机两次自续签都停在 93% 的原因。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "            case .standDown:\n"
         "                guard outcome == .wait else {",
         "            case .standDown:\n"
         "                guard false else {",
         "R10: .standDown must wait for the user to come back, then force exit"),
        # `.standDown` 的等待改成无限：不再是「放弃」，却变成了另一种永久卡住。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "            return waited < backgroundWaitSeconds ? .wait : .act",
         "            return .wait",
         "R10: the background wait must be bounded"),
        # 把等待循环里 `poll` 的结果丢掉：函数还在、单测还在，约束已经失效。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "            let outcome = poll(\n"
         "                for: currentStep,\n"
         "                waited: Date().timeIntervalSince(startedAt),\n"
         "                rounds: inactiveRounds\n"
         "            )",
         "            let outcome = SelfInstallAutoBackground.PollOutcome.wait",
         "R10: the wait loop must route through the tested step/poll functions"),
        # 让「触发转场」的日志排在 `triggerHomeTransition` **之后**：`suspend` 生效即冻结
        # 进程，这行日志就永远出不来 —— 下次真机排查又只剩「一片空白」。
        ("Seal/Features/Apps/SigningProgressView.swift",
         '                await log(logStore, "Seal 自替换：触发回主屏转场（suspend）")\n'
         "                triggerHomeTransition(app)",
         "                triggerHomeTransition(app)\n"
         '                await log(logStore, "Seal 自替换：触发回主屏转场（suspend）")',
         "R10: the suspend log must be flushed before the process is frozen"),
        # 调用点传 nil = 「回主页」这条链路重新变回静默（只声明依赖不等于接上了）。
        ("Seal/Features/Apps/AppsViewModel.swift",
         "SelfInstallAutoBackground.returnToHomeAfterSealUpload(logStore: logStore)",
         "SelfInstallAutoBackground.returnToHomeAfterSealUpload(logStore: nil)",
         "R10: both signing paths must trigger the return-home with a real log outlet"),
        # 去掉批量链路的 `.restart` 闸门：`.installing` 重复推送时会排出多个「回主页」任务，
        # 每个都写一遍日志，把真机排查要看的时序淹没。
        ("Seal/Features/Apps/AppsViewModel.swift",
         "                if stage == .installing, tick == .restart {",
         "                if stage == .installing {",
         "R10: a repeated .installing push must not spawn a second return-home"),
        # 让等待循环不再走被测过的 step()：函数还在，约束已经失效。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "            let currentStep = step(for: app.applicationState)",
         "            let currentStep = SelfInstallAutoBackground.ReturnHomeStep.triggerTransition",
         "R10: the wait loop must route through the tested step/poll functions"),
        # 重复推送也重置起点 = 「已等待」永远停在 0:0x，比不显示更像卡死。
        ("Seal/Core/Signing/InstallStageTimeline.swift",
         "        return currentStage == .installing ? .keep : .restart",
         "        return currentStage == .installing ? .restart : .restart",
         "R10: repeated .installing pushes must not reset the install clock"),
        # 让单签的「回主页」永不触发：Seal 的替换静默失败（旧版本继续跑）。
        ("Seal/Features/Apps/AppsViewModel.swift",
         "        if stage == .installing,\n           tick == .restart,\n           signingSession?.app.isSeal == true {",
         "        if stage == .installing,\n           tick == .restart,\n           signingSession?.app.isSeal == false {",
         "R10: single signing must trigger the return-home from the state layer"),
        # 界面又自己触发一次 = 双重「回主页」（两个转场 + 两个 exit(0) 兜底）。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "                withAnimation(.easeInOut(duration: 0.45)) {\n                    isReturningHome = true\n                }",
         "                withAnimation(.easeInOut(duration: 0.45)) {\n                    isReturningHome = true\n                }\n                SelfInstallAutoBackground.returnToHomeAfterSealUpload()",
         "R10: the view must not trigger the return-home"),
        # 批量链路自己再抄一份规则：漂移不会编译失败，只会让抽屉的计时变成假象。
        ("Seal/Core/Renewal/BatchRefreshSession.swift",
         "        let tick = InstallStageTimeline.tick(entering: stage, currentStage: currentStage)",
         "        let tick = stage == .installing ? InstallStageTimeline.Tick.restart : InstallStageTimeline.Tick.clear",
         "R10: Seal/Core/Renewal/BatchRefreshSession.swift must use the shared install-start rule"),
        # 自替换等待改用「超时就取消工作」：取消信号会传回 Rust 侧，
        # 可能撤销已经下发的 installation_proxy 命令 —— 把「可能还在装」变成「确定装不上」。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "            _ = try await HardTimeout.run(seconds: budget, cancelsWorkOnTimeout: false) {",
         "            _ = try await HardTimeout.run(seconds: budget, cancelsWorkOnTimeout: true) {",
         "R10: the self-replacement wait must stop waiting without cancelling the FFI"),
        # 在别处再裸等一遍 `installation.value` = 重新引入一条没有超时的等待路径。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "                try await installation.value\n                return true\n            }",
         "                try await installation.value\n                return true\n            }\n            try await installation.value",
         "R10: installation.value may only be awaited inside the watchdog"),
        # 去掉单飞闸门：91 秒内两笔自替换安装会在同一 Bundle ID 上造出两个 installd。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "        guard selfReplacementGate.acquire() else {",
         "        guard true else {",
         "R10: a second concurrent self-replacement install must be refused"),
        # 超时也解锁闸门：底层同步 FFI 很可能还在跑，第二笔就成了并发安装。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "            selfReplacementGate.release(timedOut: Self.isTimeoutInstallError(error))",
         "            selfReplacementGate.release(timedOut: false)",
         "R10: a timeout must keep the self-replacement gate closed (the FFI is still running)"),
        # 去掉共用心跳里的日志：两条路径同时重新变成「卡住时一片空白」，
        # 无法区分在装和死了。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         '                await self?.log("\\(label)仍在等待：已等待 \\(waited) 秒（installd 安装阶段不回报进度）")',
         "                _ = waited",
         "R10: the install wait needs a heartbeat — installd reports no progress"),
        # 容器不再把日志出口交给安装通道 = 日志通道永远静默（只声明依赖不等于接上了）。
        ("Seal/Application/AppContainer.swift",
         "                logStore: logStore\n            )",
         "                logStore: nil\n            )",
         "R10: AppContainer must hand the install channel a real log store"),
        # 把设备专属符号的定义挪回 `#if !targetEnvironment(simulator)` 里 = 原样重演
        # 2026-09-16 的「模拟器切片缺符号」：`build-package` 照样绿，只有
        # `swift-regression` 红。这条变异同时证明上面的检查确实在检查，而不是空转。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "    private static func isTimeoutInstallError(_ error: Error) -> Bool {\n"
         "        if error is HardTimeout.TimeoutError { return true }\n"
         "        if let failure = error as? ImportFailure,\n"
         "           failure.code == installTimeoutFailure.code {\n"
         "            return true\n"
         "        }\n"
         "        return false\n"
         "    }",
         "    #if !targetEnvironment(simulator)\n"
         "    private static func isTimeoutInstallError(_ error: Error) -> Bool {\n"
         "        if error is HardTimeout.TimeoutError { return true }\n"
         "        if let failure = error as? ImportFailure,\n"
         "           failure.code == installTimeoutFailure.code {\n"
         "            return true\n"
         "        }\n"
         "        return false\n"
         "    }\n"
         "    #endif",
         "Simulator: device-only members"),
        # 把 mutating 调用挪回 `#expect(...)` 里 = 原样重演 2026-09-16 的
        # `cannot use mutating member on immutable value: '$0' is immutable`
        # （同样只在 `swift-regression` 红）。
        ("SealTests/Installation/SelfReplacementInstallGateTests.swift",
         "        #expect(first)",
         "        #expect(gate.acquire())",
         "#expect must not call a mutating method"),
        # 把 `Set(keepMap.keys)` 写回 `Set(keepMaps.first?.keys ?? [])`：原样重演
        # `cannot convert value of type '[Any]' to expected argument type
        # 'Dictionary<String, String>.Keys'`（同样只在 `swift-regression` 红）。
        ("SealTests/Maintenance/AppMaintenanceJobTests.swift",
         "        let keptKeys = Set(keepMap.keys)",
         "        let keptKeys = Set(keepMaps.first?.keys ?? [])",
         "`?? []` after .keys/.values cannot type-check"),
    ]
    # 变异检查每一遍都会把所有源文件**重新读一遍**：200+ 文件 × 90 多遍 ≈ 2 万次磁盘读。
    # 本仓在 OneDrive 同步目录里，单次读延迟不稳定 —— 实测同一份代码整轮耗时在
    # 61–117 秒之间波动，已经贴到命令默认 120 秒超时（超时会被 SIGTERM，且**没有任何
    # 输出**，很容易误判成脚本崩了）。`base_read` 就是上面那个按路径缓存的读取器。
    for path, old, new, expected in mutations:
        original = base_read(path)
        if old not in original:
            failures.append("Mutation anchor missing: " + path)
            continue
        changed = original.replace(old, new, 1)
        _, mutated_failures = violations(lambda p: changed if p == path else base_read(p))
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
