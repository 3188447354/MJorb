import Foundation

/// 「失败 → 跳到哪个设置页」的判据。
///
/// 🔴 这里原先是一条 `failure.code.hasPrefix("SEAL-INSTALL-")` —— 于是**任何**
/// `SEAL-INSTALL-*` 错误都会把用户送去「LocalDevVPN」页，包括与本地隧道毫无关系的那些：
/// `702s`（设备存储空间不足）、`702l`（免费账号 3 应用上限）、`702f`（DRM 元数据残留）、
/// `702t`（安装超时 —— 超时 ≠ 失败）、`711…730` / `735`（签名包内容类，需重新签名）、
/// `737` / `738`（需重启 Seal）、`716`（本机签名包记录不完整）……
/// 用户点「恢复」之后被送到一个**解决不了他问题**的页面，只能自己再退回来 ——
/// 这正是「把所有问题都算到 VPN 头上」。
///
/// ⇒ 判据只收「**recovery 文案本身就在引导用户去检查 LocalDevVPN / 通道**」的码
/// （AGENTS.md §3：错误码 → 按钮动作必须用**显式码集合**，禁止前缀与数字区间）。
///
/// 配对族的码集合**不在这里重复定义** —— 单一真源是
/// `InstallFailureActionPolicy.pairingCodes`（Core 层），此处只引用。
enum InstallFailureSettingsRoute {

    /// 通道 / 本地隧道类：每一条的 `recovery` 文案都明确要求「检查是否打开 LocalDevVPN」，
    /// 或由 `AppsViewModel.presentVPNRecovery` 配套 `pendingVPNAction` 使用。
    static let localDevVPNCodes: Set<String> = [
        "SEAL-INSTALL-701",   // LocalDevVPN 未就绪
        "SEAL-INSTALL-705",   // 无法连接到设备
        "SEAL-INSTALL-706",   // 需要恢复连接（与 pendingVPNAction 配套）
        "SEAL-INSTALL-706a",  // 设置页：LocalDevVPN 未就绪
        "SEAL-INSTALL-706b",  // 设备连接失败
        "SEAL-INSTALL-706t",  // 本地通道连接超时
        "SEAL-INSTALL-708",   // 设备未响应
        "SEAL-INSTALL-710"    // 无法经本地隧道连到设备
    ]

    /// 返回 nil 表示这条失败**没有**对应的设置页可去 —— 调用方不应跳转，
    /// 由弹窗文案自己说明下一步（「知道了」语义）。
    static func route(forCode code: String) -> SettingsRoute? {
        if code.hasPrefix("SEAL-AUTH-") { return .account }
        if code.hasPrefix("SEAL-CERT-") || code.contains("CERT") { return .certificates }
        if code.hasPrefix("SEAL-PAIR-")
            || InstallFailureActionPolicy.pairingCodes.contains(code) {
            return .pairing
        }
        if localDevVPNCodes.contains(code) { return .localDevVPN }
        return nil
    }
}
