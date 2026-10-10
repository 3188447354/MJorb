import SwiftUI

/// 协议版本号：文档有实质更新时 +1，触发用户重新同意。
enum AgreementVersion {
    static let current = 1
    static let storageKey = "seal.agreedAgreementVersion"
}

/// 首次协议页与签名抽屉保持同一组几何尺度，避免两个入口出现不同的抽屉语言。
enum AgreementOnboardingLayout {
    /// 真机首屏品牌区采用实际 point 尺寸，不随预览稿放大。
    static let iconSize: CGFloat = 92
    static let iconCornerRadius: CGFloat = 22
    static let drawerCornerRadius: CGFloat = 29
    static let horizontalInset: CGFloat = 22
    static let initialDrawerFraction: CGFloat = 0.38
    static let compactContentSpacing: CGFloat = 18
    static let brandNamePointSize: CGFloat = 46
    static let brandTaglinePointSize: CGFloat = 20
    static let brandTagline = "让应用始终可用"
    static let consentTitle = "欢迎使用"
}

/// 首次启动（或协议更新后）的协议同意页。
///
/// 视觉（2026-10-10）：白色背景 + 极低饱和蓝色光斑 → 品牌区（92pt 官方图标）
/// → 系统原生确认抽屉 → "欢迎使用" → 协议说明 → "同意并继续" / "暂不使用"。
///
/// 约束：只改视觉层。协议门控（SealApp.swift）、AgreementVersion、
/// 协议正文（PrivacyNoticeView / UserAgreementView）、签名功能一律不动。
/// "暂不使用" 实际是留在协议页并提示必须同意，不写"不同意并退出"。
struct AgreementOnboardingView: View {
    var onAgreed: () -> Void
    var onDeclined: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var showDeclineHint = false
    @State private var presentationState = AgreementOnboardingPresentationState()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                background

                // 品牌区相对较短的抽屉下移，避免顶部与底部各自独立而显得割裂。
                VStack(spacing: 0) {
                    Spacer().frame(height: max(geo.safeAreaInsets.top + 140, 190))
                    brandSection
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented: $presentationState.isConsentSheetPresented) {
            AgreementConsentSheet(
                onAgreed: onAgreed,
                onOpenPolicy: { presentationState.openPolicy($0) },
                onDeclined: {
                    presentationState.decline()
                    showDeclineHint = true
                    onDeclined()
                }
            )
            .presentationDetents([.fraction(AgreementOnboardingLayout.initialDrawerFraction)])
            .presentationDragIndicator(.hidden)
            .presentationBackground(.white)
            // 协议门控不允许通过向下拖动绕过。
            .interactiveDismissDisabled()
            // 正文不改变这张 sheet 的 detent；它以独立阅读层覆盖，返回后欢迎抽屉仍在原位。
            .fullScreenCover(item: Binding<AgreementPolicyDocument?>(
                get: { presentationState.presentedPolicy },
                set: { document in
                    if document == nil {
                        presentationState.closePolicy()
                    }
                }
            )) { document in
                PolicyDocumentView(document: document) { presentationState.closePolicy() }
            }
        }
        .onAppear {
            guard !reduceMotion else {
                appeared = true
                return
            }
            withAnimation(.spring(response: 0.7, dampingFraction: 0.82)) {
                appeared = true
            }
        }
        .alert("需要您的同意", isPresented: $showDeclineHint) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("Seal 需要您同意《隐私政策》与《用户协议》才能继续使用。")
        }
        .onChange(of: showDeclineHint) { isPresented in
            // `alert` 按钮的回调仍处于 sheet 关闭动画的事务中；等 alert 实际消失后
            // 再恢复受同意门控的 sheet，避免状态写入被前一次 dismissal 吞掉。
            guard !isPresented else { return }
            presentationState.acknowledgeDecline()
        }
    }

    private var background: some View {
        ZStack {
            Color.white

            Circle()
                .fill(Color(red: 0.57, green: 0.83, blue: 1.0).opacity(0.18))
                .frame(width: 370, height: 370)
                .blur(radius: 70)
                .offset(y: -125)

            Circle()
                .fill(Color(red: 0.82, green: 0.94, blue: 1.0).opacity(0.35))
                .frame(width: 290, height: 290)
                .blur(radius: 60)
                .offset(x: 115, y: 170)

            Circle()
                .fill(Color.white.opacity(0.95))
                .frame(width: 260, height: 260)
                .blur(radius: 65)
                .offset(x: -135, y: 260)
        }
    }

    private var brandSection: some View {
        VStack(spacing: 12) {
            sealIcon

            Text("Seal")
                .font(.system(size: AgreementOnboardingLayout.brandNamePointSize, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.7)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.05, green: 0.17, blue: 0.39),
                            Color(red: 0.10, green: 0.30, blue: 0.63)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            Text(AgreementOnboardingLayout.brandTagline)
                .font(.system(size: AgreementOnboardingLayout.brandTaglinePointSize, weight: .regular))
                .foregroundStyle(Color(red: 0.22, green: 0.29, blue: 0.46))

        }
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.94)
    }

    private var sealIcon: some View {
        Group {
            if let image = UIImage(named: "SealBrandIcon") {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.23, green: 0.80, blue: 0.96),
                            Color(red: 0.00, green: 0.34, blue: 0.98)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    Image(systemName: "feather")
                        .font(.system(size: 48, weight: .medium))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(-20))
                }
            }
        }
        .frame(width: AgreementOnboardingLayout.iconSize, height: AgreementOnboardingLayout.iconSize)
        .clipShape(RoundedRectangle(cornerRadius: AgreementOnboardingLayout.iconCornerRadius, style: .continuous))
        .shadow(color: Color.blue.opacity(0.14), radius: 16, y: 8)
    }

}

/// 原生 sheet 的内容。协议门控由外层禁用交互式关闭，内容只负责明确的同意/暂不使用动作。
private struct AgreementConsentSheet: View {
    let onAgreed: () -> Void
    let onOpenPolicy: (AgreementPolicyDocument) -> Void
    let onDeclined: () -> Void

    private var drawerHorizontalInset: CGFloat { AgreementOnboardingLayout.horizontalInset }

    var body: some View {
        VStack(spacing: 0) {
            Text(AgreementOnboardingLayout.consentTitle)
                .font(.title.weight(.bold))
                .foregroundStyle(Color(red: 0.02, green: 0.07, blue: 0.17))
                .padding(.top, 24)
                .minimumScaleFactor(0.8)

            agreementDescription
                .padding(.top, 20)
                .padding(.horizontal, drawerHorizontalInset)

            Divider()
                .overlay(Color.sealHairline.opacity(0.65))
                .padding(.top, AgreementOnboardingLayout.compactContentSpacing)

            Button(action: {
                UserDefaults.standard.set(AgreementVersion.current, forKey: AgreementVersion.storageKey)
                onAgreed()
            }) {
                Text("同意并继续")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .foregroundStyle(.white)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.04, green: 0.47, blue: 1.0),
                                Color(red: 0.00, green: 0.37, blue: 0.93)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, drawerHorizontalInset)
            .padding(.top, AgreementOnboardingLayout.compactContentSpacing)

            Button("暂不使用") {
                onDeclined()
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .padding(.top, 14)
            .padding(.bottom, AgreementOnboardingLayout.compactContentSpacing)
        }
        .frame(maxWidth: .infinity)
    }

    private var agreementDescription: some View {
        VStack(alignment: .center, spacing: 8) {
            // 协议链接单独成行，避免断行
            HStack(spacing: 16) {
                Button {
                    onOpenPolicy(.privacy)
                } label: {
                    Text("《隐私政策》")
                        .foregroundStyle(Color(red: 0.00, green: 0.48, blue: 1.0))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("agreement-privacy-link")

                Button {
                    onOpenPolicy(.terms)
                } label: {
                    Text("《用户协议》")
                        .foregroundStyle(Color(red: 0.00, green: 0.48, blue: 1.0))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("agreement-terms-link")
            }

            Text("点击“同意并继续”，即表示你已阅读并同意上述协议。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}

private struct PolicyDocumentView: View {
    let document: AgreementPolicyDocument
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch document {
                case .privacy: PrivacyNoticeView()
                case .terms: UserAgreementView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onClose) {
                        Image(systemName: "chevron.backward")
                    }
                    .accessibilityLabel("返回欢迎页")
                }
            }
        }
    }
}

/// UI 测试用的启动参数：声明「本次启动视为已同意协议」。
let uiTestingAgreementAcceptedArgument = "--ui-testing-agreement-accepted"

/// 检查是否需要展示协议页：没同意过，或协议版本更新了。
func needsAgreementOnboarding(
    arguments: [String] = ProcessInfo.processInfo.arguments
) -> Bool {
    if arguments.contains(uiTestingAgreementAcceptedArgument) {
        return false
    }
    return UserDefaults.standard.integer(forKey: AgreementVersion.storageKey) < AgreementVersion.current
}
