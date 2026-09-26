enum SigningStage: String, CaseIterable, Equatable, Sendable {
    case waitingForChannel
    case preparingAccount
    case preparingBundle
    case preparingCertificate
    case preparingAppID
    case preparingProfiles
    case signing
    case pushing
    case installing
    case verifying

    func stageTitle(isRenewal: Bool) -> String {
        switch self {
        case .waitingForChannel:
            return "正在连接设备"
        case .preparingAccount:
            return "正在验证 Apple ID"
        case .preparingBundle:
            // ⚠️ 这一阶段**完全不碰 Apple**：解压 IPA、改写 Bundle 结构、归一化/瘦身，
            // 然后重新打包。**重签与打包发生在后面的 `.signing`**（真机日志里那两行
            // 「重签完成（逐 Mach-O 串行）」「打包完成（deflate）」都在 `.signing` 里）。
            //
            // 2026-09-18 真机（构建 118）：抖音（**779.7 MB**）在这一步花了 **112 秒**，
            // 而它原先被算进 `.preparingAccount`（文案「正在验证 Apple ID」、进度固定 **16%**）
            // ⇒ 用户盯着「正在验证 Apple ID 16%」等了 2 分钟，判断「Apple ID 验证卡住了」，
            // **于是去重新验证 Apple ID** —— 而那时 Seal 根本没碰 Apple ID，
            // 只是在解压他那个 780 MB 的包。
            //
            // ⇒ **这条进度文案把人直接推进了「重新验证 → 又被限流」的死循环**，
            // 与 `sign()` 覆盖错误文案那条是同一类问题（App 让用户去做没用的事），
            // 而且它发生得更早：在失败**之前**就误导了判断。
            // 同一次日志里 3105（4.3 MB）与 LiveContainer（4.9 MB）是秒级 ——
            // 所以「只有抖音卡」的真正原因是**包大**，不是账号。
            return "正在准备应用文件"
        case .preparingCertificate:
            // ⚠️ 文案**不能说「申请证书」**（2026-09-26 构建 48 真机）：这一阶段做的是
            // 「读远端证书列表 → 查本机有没有对应私钥 → 决定**复用**还是撤销重建」，
            // 而**绝大多数时候是复用** —— 真机日志里紧随这一阶段的是
            // 「证书决策：复用 Apple 生效列表中的本机证书 …976EFE08」。
            // 写成「正在申请证书」等于宣称一件没发生的事（用户会以为每轮都在建新证书）。
            // 只有 profile-only 那条路会额外保证「证书必须仍能覆盖完整 7 天」，
            // 所以它的文案仍用「正在核验当前证书」（见 `RenewalExecutionPath.stageTitle`）。
            return "正在准备证书"
        case .preparingAppID:
            // ⚠️ 同理**不能说「注册 Bundle ID」**：这一阶段先读账号已有的 App ID 列表，
            // 只对**缺失**的那些发注册请求（真机日志：「App ID 名额：本次需 1 个…需新注册 0 个」），
            // 复用时一个都不注册。与 profile-only 那条路的「正在核对 App ID」保持同一口径。
            return "正在核对 App ID"
        case .preparingProfiles:
            return "正在申请描述文件"
        case .signing:
            return isRenewal ? "正在重新签名" : "正在签名"
        case .pushing:
            return "正在传输到设备"
        case .installing:
            return "正在安装"
        case .verifying:
            return "正在验证安装"
        }
    }

    /// 真值行：这一步**在数什么**。
    ///
    /// 只在有可数对象、且计数确实属于当前阶段时才产出一行 —— 拿不出计数的阶段宁可空着，
    /// 也不写一句「正在进行中」占位（那是用措辞假装信息）。
    func unitsText(_ units: SigningWorkUnits?) -> String? {
        guard let units, units.stage == self, units.total > 0 else { return nil }
        switch self {
        case .preparingBundle:
            return "已处理 \(units.done) / \(units.total) 个文件"
        case .preparingAppID:
            // ⚠️ 计数口径是「**已就绪**」而不是「已注册」：`ApplePortalSigningService` 是在
            // App ID **解析完成**（复用的 + 新建的都算）之后才 `append` 并上报
            //（那里的注释原文：「用**已就绪的个数**而不是循环下标」）。
            // 真机日志里「需新注册 0 个」那一轮，UI 若写「已注册 1/1」就是在报一件没做的事。
            return "已准备 \(units.done) / \(units.total) 个 App ID"
        case .preparingProfiles:
            return "已取得 \(units.done) / \(units.total) 份描述文件"
        case .signing:
            return "已重签 \(units.done) / \(units.total) 个可执行文件"
        case .verifying:
            return "已核对 \(units.done) / \(units.total) 项"
        case .waitingForChannel, .preparingAccount, .preparingCertificate, .pushing, .installing:
            return nil
        }
    }
}
