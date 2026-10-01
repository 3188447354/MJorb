import SwiftUI

struct PrivacyNoticeView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                privacyRow("使用自己的 Apple ID", "凭据和证书私钥仅保存在本机钥匙串，不同步到 iCloud。")
                privacyRow("不要分享配对文件和日志", "配对文件含设备连接密钥；日志已脱敏，仍只应发送给可信支持方。")
                privacyRow("只导入信任的 IPA", "Seal 只处理你选择的 IPA；应用本身的功能和权限由其开发者负责。")
                privacyRow("网络与权限", "Wi-Fi 和 LocalDevVPN 只用于连接你的设备；定位仅用于后台续签保活，不保存或上传位置。")
            }
            .padding(20)
        }
        .navigationTitle("本机签名与凭据说明")
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
}
