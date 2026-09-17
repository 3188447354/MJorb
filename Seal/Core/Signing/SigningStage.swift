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
            // ⚠️ 这一阶段**完全不碰 Apple**：解压 IPA、改写 Bundle 结构、重签所有二进制、重新打包。
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
            return "正在申请证书"
        case .preparingAppID:
            return "正在注册 Bundle ID"
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
}
