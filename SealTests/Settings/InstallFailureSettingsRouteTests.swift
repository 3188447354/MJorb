import Foundation
import Testing
@testable import Seal

/// 「失败 → 跳到哪个设置页」的判据。
///
/// 回归目标：这里曾经是 `hasPrefix("SEAL-INSTALL-") → .localDevVPN`，
/// 于是**任何**安装族错误都会把用户送去 VPN 页 —— 包括设备存储不足、免费账号
/// 3 应用上限、DRM 元数据残留、安装超时、签名包损坏、需重启 Seal 等
/// 与本地隧道毫无关系的失败。用户点「恢复」后被送到一个解决不了他问题的页面。
struct InstallFailureSettingsRouteTests {

    // MARK: - 通道 / 本地隧道类：只有这些才去 VPN 页

    @Test(arguments: [
        "SEAL-INSTALL-701",
        "SEAL-INSTALL-705",
        "SEAL-INSTALL-706",
        "SEAL-INSTALL-706a",
        "SEAL-INSTALL-706b",
        "SEAL-INSTALL-706t",
        "SEAL-INSTALL-708",
        "SEAL-INSTALL-710"
    ])
    func channelFailuresRouteToLocalDevVPN(code: String) {
        #expect(InstallFailureSettingsRoute.route(forCode: code) == .localDevVPN)
    }

    // MARK: - 与 VPN 无关的安装族错误：不得跳转

    /// 这些码**不是**通道问题 —— 它们的 `recovery` 文案都在让用户做别的事
    /// （删 App / 重新签名 / 重新启动 Seal / 换账号）。跳去 VPN 页只会浪费一轮操作。
    @Test(arguments: [
        "SEAL-INSTALL-702",     // 通用安装失败：确认已信任、存储充足后重试
        "SEAL-INSTALL-702b",    // 安装失败 → 重新安装
        "SEAL-INSTALL-702d",    // 与设备连接断开 → 检查 Wi-Fi
        "SEAL-INSTALL-702f",    // DRM 元数据残留 → 重新砸壳
        "SEAL-INSTALL-702l",    // 免费账号 3 应用上限 → 卸载一个
        "SEAL-INSTALL-702s",    // 设备存储空间不足 → 清理存储
        "SEAL-INSTALL-702t",    // 安装超时（超时 ≠ 失败）
        "SEAL-INSTALL-704",     // 设备尚未信任 → 在 iPhone 上信任
        "SEAL-INSTALL-707a",    // 安装后验证失败 → 重试
        "SEAL-INSTALL-709",     // 安全握手未完成 → 保持前台后重试
        "SEAL-INSTALL-711",     // 签名包内容类（以下同族）
        "SEAL-INSTALL-716",
        "SEAL-INSTALL-720",
        "SEAL-INSTALL-730",
        "SEAL-INSTALL-735",     // Seal 文件共享配置缺失 → 重新获取完整 IPA
        "SEAL-INSTALL-737",     // 自更新事务未就绪 → 重启 Seal
        "SEAL-INSTALL-738",     // 上一笔安装仍在进行 → 重启 Seal
        "SEAL-INSTALL-500"      // 安装流程未预期错误
    ])
    func nonChannelInstallFailuresDoNotRouteAnywhere(code: String) {
        #expect(InstallFailureSettingsRoute.route(forCode: code) == nil)
    }

    // MARK: - 配对族（前缀是 SEAL-INSTALL- 但属于配对）

    @Test(arguments: ["SEAL-INSTALL-703", "SEAL-INSTALL-707"])
    func pairingPrefixedInstallFailuresRouteToPairing(code: String) {
        #expect(InstallFailureSettingsRoute.route(forCode: code) == .pairing)
    }

    @Test
    func pairingFailuresRouteToPairing() {
        #expect(InstallFailureSettingsRoute.route(forCode: "SEAL-PAIR-211") == .pairing)
        #expect(InstallFailureSettingsRoute.route(forCode: "SEAL-PAIR-203b") == .pairing)
    }

    // MARK: - 其余家族保持不变

    @Test
    func accountAndCertificateFailuresKeepTheirRoutes() {
        #expect(InstallFailureSettingsRoute.route(forCode: "SEAL-AUTH-110") == .account)
        #expect(InstallFailureSettingsRoute.route(forCode: "SEAL-AUTH-104f") == .account)
        #expect(InstallFailureSettingsRoute.route(forCode: "SEAL-CERT-204e") == .certificates)
        #expect(InstallFailureSettingsRoute.route(forCode: "SEAL-CERT-240") == .certificates)
    }

    @Test
    func unrelatedCodesAreNotRouted() {
        #expect(InstallFailureSettingsRoute.route(forCode: "SEAL-IPA-212") == nil)
        #expect(InstallFailureSettingsRoute.route(forCode: "SEAL-SELF-114") == nil)
        #expect(InstallFailureSettingsRoute.route(forCode: "") == nil)
    }

    // MARK: - 集合一致性

    /// 通道码集合必须与另外三个动作集合**不相交** ——
    /// 重叠意味着同一条失败既「可安全重跑安装」又要「去检查 VPN」，
    /// 两条判据会在不同界面上给出不同引导。
    @Test
    func localDevVPNCodesAreDisjointFromActionSets() {
        let vpn = InstallFailureSettingsRoute.localDevVPNCodes
        #expect(vpn.isDisjoint(with: InstallFailureActionPolicy.acknowledgeCodes))
        #expect(vpn.isDisjoint(with: InstallFailureActionPolicy.resignCodes))
        #expect(vpn.isDisjoint(with: InstallFailureActionPolicy.pairingCodes))
    }

    /// 通道码集合里不该出现配对码 —— 它们有各自的页面。
    @Test
    func localDevVPNCodesExcludePairingCodes() {
        for code in InstallFailureActionPolicy.pairingCodes {
            #expect(InstallFailureSettingsRoute.localDevVPNCodes.contains(code) == false)
        }
    }
}
