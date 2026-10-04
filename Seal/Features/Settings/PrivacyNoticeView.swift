import SwiftUI

/// 隐私政策：整合原"本机签名与凭据说明"的安全提示 + 完整隐私说明
struct PrivacyNoticeView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 安全使用（原有内容）
                Text("安全使用")
                    .font(.headline)
                    .padding(.top, 4)
                privacyRow("使用自己的 Apple ID", "凭据和证书私钥仅保存在本机钥匙串，不同步到 iCloud。")
                privacyRow("不要分享配对文件和日志", "配对文件含设备连接密钥；日志已脱敏，仍只应发送给可信支持方。")
                privacyRow("只导入信任的 IPA", "Seal 只处理你选择的 IPA；应用本身的功能和权限由其开发者负责。")
                privacyRow("网络与权限", "Wi-Fi 和 LocalDevVPN 只用于连接你的设备；定位仅用于后台续签保活，不保存或上传位置。")

                Divider()
                    .padding(.vertical, 8)

                // 隐私政策（新增）
                Text("隐私政策")
                    .font(.headline)
                Text("更新日期：2026-10-05")
                    .font(.caption)
                    .foregroundStyle(Color.sealTextSecondary)

                policySection(
                    title: "我们收集什么",
                    body: "Apple ID 和密码仅存储在你设备的 iOS 钥匙串中，仅用于向 Apple 服务器进行签名认证，不会发送到任何第三方服务器。设备 UDID、型号等仅用于向 Apple 注册设备和申请描述文件。应用列表和日志仅存储在你的设备本地，日志中的敏感信息会自动脱敏。"
                )
                policySection(
                    title: "我们不做什么",
                    body: "没有用户账号系统，没有数据分析或行为追踪，没有广告，没有自有服务器，所有数据都不离开你的设备（除了必要的 Apple 通信）。"
                )
                policySection(
                    title: "第三方服务",
                    body: "签名过程中会连接到第三方 Anisette 服务器（用于 Apple 认证握手）。这些服务器仅参与认证流程，不存储你的个人数据。"
                )
                policySection(
                    title: "你的权利",
                    body: "随时删除 Apple ID（设置 → 账号管理），随时清空日志（设置 → 支持与关于 → 日志），卸载 App 即删除所有本地数据。"
                )
            }
            .padding(20)
        }
        .navigationTitle("隐私政策")
        .navigationBarTitleDisplayMode(.inline)
        .sealScreenBackground()
    }

    private func privacyRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.sealSuccess)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Color.sealTextSecondary)
            }
            Spacer()
        }
        .padding(16)
        .glassSurface(cornerRadius: 14)
    }

    private func policySection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body.weight(.semibold))
            Text(body)
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .lineSpacing(4)
        }
        .padding(16)
        .glassSurface(cornerRadius: 14)
    }
}
