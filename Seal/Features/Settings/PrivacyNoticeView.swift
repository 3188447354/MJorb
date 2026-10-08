import SwiftUI

/// 隐私政策（企业级）：完整法务口径，2026-10-07 定稿。
struct PrivacyNoticeView: View {
var body: some View {
ScrollView {
VStack(alignment:.leading, spacing: 18) {
Text("生效日期：2026 年 10 月 7 日")
.font(.caption)
.foregroundStyle(Color.sealTextSecondary)
.padding(.top, 4)

policySection(
title: "引言",
body: "Seal（以下简称「本应用」）由个人开发者（以下简称「我们」）提供。我们深知个人信息对您的重要性，并致力于保护您的隐私。本隐私政策旨在向您说明我们如何收集、使用、存储和保护您的信息，以及您享有的权利。使用本应用，即表示您已阅读、理解并同意本隐私政策。"
)

policySection(
title: "一、定义",
body: "个人信息：以电子或其他方式记录的与已识别或可识别的自然人有关的各种信息。\n敏感个人信息：一旦泄露或非法使用，可能导致个人受到歧视或人身、财产安全受到严重危害的信息，包括账号密码、设备标识符等。\n本地处理：数据仅在您的设备上处理，不传输至任何服务器。"
)

policySection(
title: "二、我们收集的信息及用途",
body: "Apple ID（邮箱）与密码/会话令牌仅存储于 iOS 钥匙串（本机，不同步 iCloud），仅用于向 Apple 服务器进行签名认证，不会发送至除 Apple 官方服务器及 Anisette 认证握手服务器之外的任何第三方。\n\n设备 UDID、型号、系统版本仅用于向 Apple 注册设备和申请描述文件，存储于本地数据库。\n\n已安装应用列表、签名证书信息、描述文件均存储于设备本地，仅用于展示、续签管理与签名。\n\n应用运行日志存储于设备本地，写入前经过自动脱敏处理，敏感信息会被替换为占位符。您可随时在设置中清空日志。\n\n快捷指令触发后台续签时，使用静音音频保活机制（播放人耳不可闻的静音音频），以防止系统挂起续签任务。"
)

policySection(
title: "三、我们不收集的信息",
body: "我们不收集用户行为数据，无数据分析、无行为追踪；不集成任何广告 SDK，无广告；不收集崩溃日志并上传；不建立用户账号系统；不运营自有服务器。所有数据均不离开您的设备（除上述必要的 Apple 通信外）。"
)

policySection(
title: "四、第三方服务",
body: "签名过程中需要与 Apple 官方服务器通信（账号认证、设备注册、描述文件申请、证书管理），数据处理遵循 Apple 的隐私政策。\n\nApple 认证握手需要 Anisette 数据，会连接到第三方 Anisette 服务器获取。这些服务器仅参与认证流程的握手环节，不存储您的个人数据。"
)

policySection(
title: "五、数据存储与安全",
body: "1. 除必要的 Apple 通信外，所有数据均存储于您的设备本地。\n2. Apple ID 凭据存储于 iOS 钥匙串，设置不同步至 iCloud，仅本机可访问。\n3. 与 Apple 服务器的通信均使用 HTTPS/TLS 加密。\n4. 仅收集实现功能所必需的最少信息。\n5. 数据保留至您删除相关账号、清空日志或卸载应用为止。"
)

policySection(
title: "六、您的权利",
body: "1. 访问与更正：可在应用内查看已保存的 Apple ID、设备列表、应用列表。\n2. 删除：可随时删除 Apple ID、清空日志，相关数据将从本地移除。\n3. 撤回授权：可在 iOS 设置中撤回系统权限，相关功能可能受限。\n4. 注销：本应用无账号系统，卸载应用即终止数据处理。"
)

policySection(
title: "七、未成年人保护",
body: "本应用不面向未成年人提供服务。如果您是未满 18 周岁的未成年人，请在监护人指导下阅读本政策并使用本应用。"
)

policySection(
title: "八、隐私政策的更新",
body: "我们可能根据功能调整或法律法规要求更新本隐私政策。更新后将在应用内显著位置提示您查阅。继续使用本应用即表示您接受更新后的政策。"
)

policySection(
title: "九、联系我们",
body: "如您对本隐私政策有任何疑问、意见或投诉，可通过应用内「加入社群」联系开发者。我们将在合理期限内予以答复。"
)

Text("本隐私政策是《Seal 用户协议》不可分割的组成部分。")
.font(.caption)
.foregroundStyle(Color.sealTextSecondary)
.padding(.top, 8)
}
.padding(20)
}
.navigationTitle("\(AgreementMetadata.Privacy.title)")
.navigationBarTitleDisplayMode(.inline)
.toolbar {
    ToolbarItem(placement: .principal) {
        VStack(spacing: 2) {
            Text(AgreementMetadata.Privacy.title)
                .font(.headline)
            Text("v\(AgreementVersion.current) · \(AgreementMetadata.Privacy.effectiveDate)生效")
                .font(.caption2)
                .foregroundStyle(Color.sealTextSecondary)
        }
    }
}
.sealScreenBackground()
}

private func policySection(title: String, body: String) -> some View {
VStack(alignment:.leading, spacing: 6) {
Text(title)
.font(.body.weight(.semibold))
Text(body)
.font(.subheadline)
.foregroundStyle(Color.sealTextSecondary)
.lineSpacing(4)
}
.frame(maxWidth: .infinity, alignment: .leading)
.padding(16)
.glassSurface(cornerRadius: 14)
}
}
