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
    # 用 find 而不是 index：变异把 guard 换掉时，这里要报「检查失败」而不是抛异常。
    lookup_at = sweep_body.find("guard let keepingUUID = keepingByBundleID[")
    remove_at = sweep_body.find("try Provision.removeProvisioningProfile(id: profileUUID)")
    check(lookup_at != -1 and remove_at != -1 and lookup_at < remove_at,
          "R08: a profile may only be deleted after its managed bundle-id lookup succeeded")
    coordinator_source = load("Seal/Core/Signing/SigningCoordinator.swift")
    check("SignedArtifactProfileReader.embeddedProfiles(in: signedData)" in coordinator_source,
          "R08: post-install cleanup must use the whole embedded profile set")
    maintenance_source = load("Seal/Core/Maintenance/AppMaintenanceJob.swift")
    check("profileSweeper" in maintenance_source and "profileKeepMap" in maintenance_source,
          "R08: idle maintenance must sweep stale device profiles")
    check("guard let uuid = record.provisioningProfileUUID" in maintenance_source,
          "R08: records without a profile UUID must be skipped, never guessed")
    # 扩展记录是「乐观值」：applySigningResult 在签名阶段就写它，不等安装校验。
    # 签名成功但安装失败时，扩展记录指向一份设备上不存在的 profile ——
    # 拿它当保留集合会删掉真正在用的那一份，扩展当场失效。
    check("guard record.signedArtifactStatus == .installed else { continue }" in maintenance_source,
          "R08: extension profile ids are optimistic — only trust them after a verified install")

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
        "static func returnToHomeAfterSealUpload()",
        "private static func triggerHomeTransition"
    )))
    # 结构还在不等于还在用：等待循环必须真的走 step()，否则守卫守的是一个没人调的函数。
    check("switch step(for: app.applicationState)" in return_home,
          "R10: the wait loop must route through the tested step function")
    check("case .waitForForeground: try? await Task.sleep" in return_home
          and "for _ in 0...inactiveRetryLimit" in return_home,
          "R10: .inactive must actually be waited out, not merely skipped")
    # `.standDown` 的语义是「不触发转场、也不强杀进程」：用户已经自己切走了，
    # 再 exit(0) 会和用户的操作打架。
    check("case .standDown: return false" in return_home,
          "R10: a real background transition must not kill the process")
    check("exit(0)" in return_home,
          "R10: the exit fallback must stay reachable on every non-background path")
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
    check("SelfInstallAutoBackground.returnToHomeAfterSealUpload()" in apps_view,
          "R10: the state layer must actually call the return-home action")
    # 界面自己再触发一次 = 双重「回主页」（两个系统转场 + 两个 exit(0) 兜底）。
    check("SelfInstallAutoBackground.returnToHomeAfterSealUpload()" not in progress_view,
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
    check("自替换安装仍在等待：" in self_replace
          and "Self.selfReplacementHeartbeatNanoseconds" in self_replace,
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
        # 先在**未去注释**的原文上做一次廉价子串判断再决定是否去注释：
        # 这个循环要跑遍 200+ 个文件、而守卫总共要把 `violations()` 跑 90 多遍，
        # 对每个文件都做一遍去注释会让守卫慢 5 秒（实测）。全仓只有个别文件
        # 与目标平台条件编译有关。
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
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "guard let keepingUUID = keepingByBundleID[profileBundleID.lowercased()] else {\n                continue\n            }",
         "let keepingUUID = keepingByBundleID[profileBundleID.lowercased()] ?? \"\"",
         "R08: a profile may only be deleted after its managed bundle-id lookup succeeded"),
        ("Seal/Core/Maintenance/AppMaintenanceJob.swift",
         "guard let uuid = record.provisioningProfileUUID,",
         "let uuid = record.provisioningProfileUUID ?? \"\",",
         "R08: records without a profile UUID must be skipped"),
        ("Seal/Core/Maintenance/AppMaintenanceJob.swift",
         "guard record.signedArtifactStatus == .installed else { continue }",
         "guard true else { continue }",
         "R08: extension profile ids are optimistic"),
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
        # 把 `.background` 也接上转场：用户已经自己切走了，再去触发一次就是和用户的操作打架。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "        case .background:\n            return .standDown",
         "        case .background:\n            return .triggerTransition",
         "R10: only a real background transition means the user left"),
        # `.inactive` 等够 3 秒改成直接放弃等待：控制中心一遮挡就会走到 exit(0)，
        # 在用户还在前台时把进程杀掉，安装永远完不成。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "            case .waitForForeground:\n                try? await Task.sleep(nanoseconds: inactiveRetryNanoseconds)",
         "            case .waitForForeground:\n                break",
         "R10: .inactive must actually be waited out"),
        # 让等待循环不再走被测过的 step()：函数还在，约束已经失效。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "            switch step(for: app.applicationState) {",
         "            switch app.applicationState {",
         "R10: the wait loop must route through the tested step function"),
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
        # 去掉等待心跳：真机上重新变成「卡住时一片空白」，无法区分在装和死了。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         '                await self?.log("自替换安装仍在等待：已等待 \\(waited) 秒（installd 安装阶段不回报进度）")',
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
