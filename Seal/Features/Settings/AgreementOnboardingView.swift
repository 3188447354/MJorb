import SwiftUI

/// 协议版本号：文档有实质更新时 +1，触发用户重新同意。
enum AgreementVersion {
    static let current = 1
    static let storageKey = "seal.agreedAgreementVersion"
}

/// 首次启动（或协议更新后）的协议同意页。
///
/// 视觉：开屏欢迎页 + 底部确认 Sheet。
/// 上半：品牌图标（76pt）→ "Seal" → 副标题"为你的应用，保持可用。"
/// 下半：白色底部 Sheet（圆角 28，非系统 sheet，不可下拉关闭）→
///   标题"欢迎使用 Seal" → 两行说明（协议名可点）→ "同意并继续" / "暂不使用"。
///
/// 约束：只改视觉层。协议门控（SealApp.swift）、AgreementVersion、
/// 协议正文（PrivacyNoticeView / UserAgreementView）、签名功能一律不动。
struct AgreementOnboardingView: View {
    var onAgreed: () -> Void
    var onDeclined: () -> Void

    @State private var showDeclineHint = false

    var body: some View {
        VStack(spacing: 0) {
            // 上半：品牌区，居中
            Spacer()
            brandHeader
            Spacer()
            // 下半：底部确认 Sheet
            bottomSheet
        }
        .sealScreenBackground()
        .alert("需要您的同意", isPresented: $showDeclineHint) {
            Button("好的", role: .cancel) { }
        } message: {
            Text("Seal 需要您同意《隐私政策》与《用户协议》才能继续使用。")
        }
    }

    // MARK: - 上半屏：品牌

    private var brandHeader: some View {
        VStack(spacing: 14) {
            Image("SealBrandIcon")
                .resizable()
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: Color.sealAccent.opacity(0.18), radius: 12, y: 6)

            Text("Seal")
                .font(.system(size: 27, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text("为你的应用，保持可用。")
                .font(.system(size: 15))
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - 下半屏：底部确认 Sheet

    /// 自定义底部 Sheet：白色、顶部圆角 28、不可下拉关闭。
    private var bottomSheet: some View {
        VStack(spacing: 0) {
            // 拖拽指示条（纯视觉装饰）
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 16)

            Text("欢迎使用 Seal")
                .font(.system(size: 22, weight: .bold))
                .padding(.bottom, 12)

            agreementNotes
                .padding(.bottom, 20)

            Button("同意并继续") {
                UserDefaults.standard.set(AgreementVersion.current, forKey: AgreementVersion.storageKey)
                onAgreed()
            }
            .sealPrimaryAction(cornerRadius: 14)
            .padding(.bottom, 8)

            Button("暂不使用") {
                showDeclineHint = true
                onDeclined()
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Color.sealTextSecondary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .background(Color.white)
        .clipShape(
            UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 28, topTrailing: 28)
            )
        )
        .shadow(color: .black.opacity(0.08), radius: 16, y: -4)
    }

    /// 两行说明：《隐私政策》《用户协议》可点，分别进对应页面。
    /// 用流式布局，支持 Dynamic Type 放大不裁切。
    private var agreementNotes: some View {
        VStack(spacing: 8) {
            // 第一行：使用前，请阅读《隐私政策》和《用户协议》。
            HStack(spacing: 0) {
                Text("使用前，请阅读")
                    .foregroundStyle(Color.sealTextSecondary)
                NavigationLink { PrivacyNoticeView() } label: {
                    Text("《隐私政策》")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.sealAccent)
                }
                .buttonStyle(.plain)
                Text("和")
                    .foregroundStyle(Color.sealTextSecondary)
                NavigationLink { UserAgreementView() } label: {
                    Text("《用户协议》")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.sealAccent)
                }
                .buttonStyle(.plain)
                Text("。")
                    .foregroundStyle(Color.sealTextSecondary)
            }
            // 第二行：点击"同意并继续"，即表示你已阅读并同意上述协议。
            Text("点击“同意并继续”，即表示你已阅读并同意上述协议。")
                .foregroundStyle(Color.sealTextSecondary)
        }
        .font(.system(size: 14))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        // 协议链接最小点击高度 44pt
        .padding(.vertical, 4)
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
/// 直到 2026-10-08 才第一次真的跑出来，很容易被误当成「本轮改动引入的回归」。
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
