import SwiftUI

/// 用户协议（企业级）：完整法务口径，2026-10-07 定稿。
struct UserAgreementView: View {
var body: some View {
ScrollView {
VStack(alignment:.leading, spacing: 18) {
Text("生效日期：2026 年 10 月 7 日")
.font(.caption)
.foregroundStyle(Color.sealTextSecondary)
.padding(.top, 4)

policySection(
title: "引言",
body: "欢迎使用 Seal（以下简称"本应用"）。本应用由个人开发者（以下简称"我们"）提供。在使用本应用之前，请您仔细阅读本用户协议（以下简称"本协议"）的全部条款，特别是免除或限制责任的条款。使用本应用，即表示您已阅读、理解并同意受本协议约束。如您不同意本协议，请勿使用本应用。"
)

policySection(
title: "一、定义",
body: "1. 本应用：指名为"Seal"的 iOS 应用程序及其后续更新版本。\n2. 签名：指使用 Apple ID 对 IPA 安装包进行代码签名的过程。\n3. 描述文件：指 Apple 颁发的 provisioning profile，用于授权应用在设备上运行。\n4. 用户：指下载、安装或使用本应用的自然人。"
)

policySection(
title: "二、服务内容与许可",
body: "本应用是一款运行于您个人设备上的 iOS 应用签名工具，主要功能包括：使用您自己的 Apple ID 为 IPA 安装包进行签名；将签名后的应用安装到您的设备；管理描述文件的有效期，并提供续签提醒与自动续签功能。\n\n我们授予您一项个人的、非排他的、不可转让的、不可转授权的许可，允许您在本协议约定的范围内使用本应用。\n\n未经我们书面许可，您不得：对本应用进行反编译、破解；复制、分发、出租、销售本应用；删除本应用中的版权标识；将本应用用于本协议约定之外的用途。"
)

policySection(
title: "三、用户行为规范",
body: "您只能使用本人合法持有的 Apple ID 进行签名，不得使用、盗用或冒用他人的 Apple ID。因使用非本人账号产生的一切法律后果，由您自行承担。\n\n您导入并签名的 IPA 文件应为您合法获得。不得使用本应用对侵犯他人知识产权的应用进行签名、分发或传播。\n\n您不得利用本应用从事任何违反法律法规的行为，包括分发盗版应用、传播恶意软件、从事违法犯罪活动等。\n\n请妥善保管您的设备与 Apple ID 凭据。本应用在任何情况下都不会索取您的 Apple ID 密码。"
)

policySection(
title: "四、免责声明",
body: "您理解并同意：Apple 可能随时调整开发者政策、吊销签名证书、限制或封禁 Apple ID 的签名权限。由此导致的签名失败、应用无法安装或无法打开，我们不承担任何责任。\n\n本应用按"现状"提供，我们不对服务的持续可用性、稳定性、签名成功率作任何明示或默示的担保。免费 Apple ID 的描述文件有效期通常为 7 天，需要定期续签；因逾期未续签导致应用无法打开的，由您自行负责。\n\n您的签名数据与 Apple ID 相关信息均存储于您的设备本地（详见《隐私政策》）。因设备丢失、损坏、系统故障等原因导致的数据丢失，我们不承担责任。\n\n您通过本应用安装的第三方应用，其质量、安全性和合法性由该应用的提供者负责，我们不承担责任。\n\n在法律允许的最大范围内，我们对因使用或无法使用本应用而产生的任何间接的、附带的、特殊的、后果性的损失不承担责任。"
)

policySection(
title: "五、知识产权",
body: "本应用本身（包括软件代码、界面设计、文案、图标）的著作权及其他知识产权归开发者所有。本协议未授予您除许可使用之外的任何知识产权。"
)

policySection(
title: "六、服务的变更、中断与终止",
body: "我们可能根据需要对功能进行调整或更新，恕不另行通知。\n\n因系统维护、网络故障、Apple 政策调整等原因，服务可能暂时中断。\n\n如您违反本协议，我们有权暂停或终止向您提供服务。您可以随时通过删除本应用的方式终止使用。"
)

policySection(
title: "七、隐私保护",
body: "我们如何收集、使用、存储和保护您的个人信息，请参阅应用内的《隐私政策》。《隐私政策》是本协议不可分割的组成部分，与本协议具有同等法律效力。"
)

policySection(
title: "八、争议解决",
body: "本协议的订立、效力、解释、履行及争议解决，均适用中华人民共和国法律。因本协议引起的争议，双方应首先通过友好协商解决；协商不成的，任何一方均有权向开发者所在地有管辖权的人民法院提起诉讼。"
)

policySection(
title: "九、其他条款",
body: "1. 可分割性：如本协议的任何条款被认定为无效，不影响其他条款的效力。\n2. 完整协议：本协议与《隐私政策》共同构成双方就本应用使用事宜的完整约定。\n3. 解释权：在法律允许的范围内，本协议的解释权归开发者所有。\n4. 生效：本协议自您首次使用本应用之日起生效。"
)

Text("如您对本协议有任何疑问，可通过应用内"加入社群"联系开发者。")
.font(.caption)
.foregroundStyle(Color.sealTextSecondary)
.padding(.top, 8)
}
.padding(20)
}
.navigationTitle("用户协议")
.navigationBarTitleDisplayMode(.inline)
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
.padding(16)
.glassSurface(cornerRadius: 14)
}
}
