import SwiftUI

/// 协议版本号：文档有实质更新时 +1，触发用户重新同意。
enum AgreementVersion {
    static let current = 1
    static let storageKey = "seal.agreedAgreementVersion"
}

/// 首次启动（或协议更新后）的协议同意页。
/// 视觉采用"信任摘要"方案：标题 + 两条信任摘要 + 两个协议入口 + 同意按钮。
struct AgreementOnboardingView: View {
    var onAgreed: () -> Void
    var onDeclined: () -> Void

    @State private var showDeclineHint = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部内容（一屏放下，不滚动）
            VStack(spacing: 0) {
                // 品牌图标
                Image("SealBrandIcon")
                    .resizable()
                    .frame(width: 62, height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.top, 40)
                    .padding(.bottom, 16)

                // 标题（单行）
                Text("欢迎使用 Seal")
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.bottom, 8)

                // 副标题（单行）
                Text("开始前，请花一分钟了解我们如何处理你的数据。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.sealTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.bottom, 24)

                // 信任摘要
                VStack(spacing: 0) {
                    trustRow(
                        icon: "iphone",
                        title: "优先在本机处理",
                        detail: "账号、设备与签名资料默认保留在此设备。"
                    )
                    Divider()
                        .padding(.leading, 44)
                    trustRow(
                        icon: "lock.shield",
                        title: "仅用于必要的 Apple 通信",
                        detail: "需要签名时，才与 Apple 服务建立加密连接。"
                    )
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 16)

                // 协议入口
                VStack(spacing: 8) {
                    NavigationLink { PrivacyNoticeView() } label: {
                        documentRow(
                            title: AgreementMetadata.Privacy.title,
                            date: AgreementMetadata.Privacy.effectiveDate,
                            icon: "doc.text"
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink { UserAgreementView() } label: {
                        documentRow(
                            title: AgreementMetadata.Terms.title,
                            date: AgreementMetadata.Terms.effectiveDate,
                            icon: "doc.plaintext"
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 18)

            Spacer(minLength: 8)

            // 底部操作区（固定在安全区上方）
            VStack(spacing: 0) {
                // 同意文案（协议名可点，单行）
                HStack(spacing: 0) {
                    Text("继续即表示你已阅读并同意")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.sealTextSecondary)
                    NavigationLink { PrivacyNoticeView() } label: {
                        Text("《\(AgreementMetadata.Privacy.title)》")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.sealAccent)
                    }
                    .buttonStyle(.plain)
                    Text("和")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.sealTextSecondary)
                    NavigationLink { UserAgreementView() } label: {
                        Text("《\(AgreementMetadata.Terms.title)》")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.sealAccent)
                    }
                    .buttonStyle(.plain)
                    Text("。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.sealTextSecondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

                // 主按钮
                Button("同意并继续") {
                    UserDefaults.standard.set(AgreementVersion.current, forKey: AgreementVersion.storageKey)
                    onAgreed()
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .background(Color.sealAccent, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                // 次按钮
                Button("暂不使用") {
                    showDeclineHint = true
                    onDeclined()
                }
                .font(.system(size: 14))
                .foregroundStyle(Color.sealTextSecondary)
                .padding(.vertical, 8)
            }
            .padding(.bottom, 20)
        }
        .sealScreenBackground()
        .alert("需要您的同意", isPresented: $showDeclineHint) {
            Button("好的", role: .cancel) { }
        } message: {
            Text("Seal 需要您同意《隐私政策》与《用户协议》才能继续使用。")
        }
    }

    /// 信任摘要行：图标 + 粗体标题 + 描述
    private func trustRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.sealAccent)
                .frame(width: 28, height: 28)
                .background(Color.sealAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sealTextSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.vertical, 12)
    }

    /// 协议文档行：图标 + 名称 + 日期 + 箭头
    private func documentRow(title: String, date: String, icon: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(Color.sealAccent)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(date)
                .font(.system(size: 12))
                .foregroundStyle(Color.sealTextSecondary)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.sealTextSecondary.opacity(0.6))
        }
        .padding(14)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .shadow(color: Color.black.opacity(0.06), radius: 8, y: 3)
    }
}

/// UI 测试用的启动参数：声明「本次启动视为已同意协议」。
///
/// 🔴 为什么必须有（2026-10-07 引入本门控时漏掉的同步）：
/// 门控把**整个** `RootTabView` 挡在协议页后面，而 `SealUITests` 的用例都是
/// `app.launch()` 之后直接去找根界面的元素（tab 栏 / 「待签名，N 个」/ 导入入口）
/// ⇒ 它们全部停在协议页，7 个用例一起红，
/// `swift-regression` 从 2026-10-05 最后一次全绿之后再没绿过。
/// 而中间几十次 run 全是 `cancelled`（被新推送顶掉），这个红点一直没暴露 ——
/// 直到 2026-10-08 才第一次真的跑完并报出来，很容易被误当成「本轮改动引入的回归」。
///
/// ⚠️ 只认**显式**参数，**不**写成「`--ui-testing-` 前缀」这类隐式规则
/// （AGENTS.md §3：显式集合，禁止前缀与数字区间）：
/// 前缀规则会让「到底哪些参数能开门」不可枚举，下一个加 UI 测试的人无从自查。
///
/// 真实用户拿不到这个参数：iOS 上启动参数只有 Xcode / `simctl launch` 能传，
/// 别的 App 无法为 Seal 指定 —— 所以门控对真实首启的行为完全不变。
let uiTestingAgreementAcceptedArgument = "--ui-testing-agreement-accepted"

/// 检查是否需要展示协议页：没同意过，或协议版本更新了。
///
/// - Parameter arguments: 可注入，便于单测；默认取进程启动参数。
func needsAgreementOnboarding(
    arguments: [String] = ProcessInfo.processInfo.arguments
) -> Bool {
    if arguments.contains(uiTestingAgreementAcceptedArgument) {
        return false
    }
    return UserDefaults.standard.integer(forKey: AgreementVersion.storageKey) < AgreementVersion.current
}
