import SwiftUI

/// 协议版本号：文档有实质更新时 +1，触发用户重新同意。
enum AgreementVersion {
    static let current = 1
    static let storageKey = "seal.agreedAgreementVersion"
}

/// 首次启动（或协议更新后）的协议同意页。
struct AgreementOnboardingView: View {
    var onAgreed: () -> Void
    var onDeclined: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.sealAccent)
                .padding(.bottom, 20)

            Text("欢迎使用 Seal")
                .font(.title.weight(.bold))
                .padding(.bottom, 8)

            Text("在使用之前，请阅读并同意以下文档")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .padding(.bottom, 28)

            VStack(spacing: 12) {
                NavigationLink { PrivacyNoticeView() } label: {
                    agreementRow(title: "隐私政策", icon: "lock.shield")
                }
                .buttonStyle(.plain)

                NavigationLink { UserAgreementView() } label: {
                    agreementRow(title: "用户协议", icon: "doc.text")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)

            Text("点击"同意并继续"，即表示您已阅读并同意《隐私政策》与《用户协议》的全部内容。")
                .font(.caption)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 20)

            Button("同意并继续") {
                UserDefaults.standard.set(AgreementVersion.current, forKey: AgreementVersion.storageKey)
                onAgreed()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Button("不同意") {
                onDeclined()
            }
            .font(.subheadline)
            .foregroundStyle(Color.sealTextSecondary)
            .padding(.bottom, 32)
        }
        .sealScreenBackground()
    }

    private func agreementRow(title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.sealAccent)
                .frame(width: 24)
            Text(title)
                .font(.body)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Color.sealTextSecondary)
        }
        .padding(16)
        .glassSurface(cornerRadius: 14)
    }
}

/// 检查是否需要展示协议页：没同意过，或协议版本更新了。
func needsAgreementOnboarding() -> Bool {
    UserDefaults.standard.integer(forKey: AgreementVersion.storageKey) < AgreementVersion.current
}
