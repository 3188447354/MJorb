import SwiftUI
import UIKit

struct InstalledAppActionSheet: View {
    let app: AppRecord
    @ObservedObject var viewModel: AppsViewModel
    let onRenew: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SealDrawer(title: "应用操作") {
            VStack(alignment: .leading, spacing: 16) {
                appHeader
                signingSummaryCard
            }
            .padding(.bottom, 12)
        } footer: {
            VStack(spacing: 10) {
                Button(AppSigningPresentationHelpers.renewNowAction) {
                    dismiss()
                    onRenew()
                }
                .sealPrimaryAction(cornerRadius: 14)


            }
        }
    }

    private var appHeader: some View {
        HStack(spacing: 14) {
            icon(size: 56)
            VStack(alignment: .leading, spacing: 5) {
                Text(app.displayName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text("v\(app.version) · \(app.size.sealFormattedByteCount)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.sealTextSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var signingSummaryCard: some View {
        VStack(spacing: 0) {
            metadataRow("签名账户", accountSummary)
            Divider().padding(.leading, 14)
            metadataRow("Apple 证书", certificateStatus, valueColor: certificateStatusColor)
            Divider().padding(.leading, 14)
            metadataRow("描述文件", profileStatusSummary, valueColor: profileStatusColor)
            Divider().padding(.leading, 14)
            metadataRow("有效期至", expirySummary, valueColor: expiryColor)
            Divider().padding(.leading, 14)
            metadataRow("Bundle ID", bundleIDSummary, usesMiddleTruncation: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .glassSurface(cornerRadius: 18)
    }

    private func metadataRow(
        _ title: String,
        _ value: String,
        valueColor: Color = Color.sealTextSecondary,
        usesMiddleTruncation: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.primary)
                .layoutPriority(1)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(usesMiddleTruncation ? .middle : .tail)
                .minimumScaleFactor(0.68)
                .allowsTightening(true)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func icon(size: CGFloat) -> some View {
        Group {
            if let data = viewModel.iconData[app.id], let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(10)
                    .foregroundStyle(Color.sealAccent)
                    .background(Color.sealSurfaceElevated)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }

    /// 与**真正的续签判据同源**（`RenewalAccountResolver`）。
    ///
    /// 旧实现按「记录里的 UUID 反查得到账号吗」决定文案，而续签走的是解析器
    ///（含同 Team 回退）⇒ 界面显示「未记录·自动选择」、行为却是拒绝，
    /// **显示与行为正好相反**（2026-09-24 构建 34 真机：三个应用全部如此）。
    private var resolution: RenewalAccountResolver.Resolution {
        RenewalAccountResolver.resolve(
            recordedAccountID: app.accountID,
            recordedTeamID: app.signingTeamID,
            accounts: viewModel.accounts
        )
    }

    private var accountSummary: String {
        switch resolution {
        case .resolved(let id):
            if let account = viewModel.accounts.first(where: { $0.id == id }) {
                return viewModel.fullEmail(for: account)
            }
            return "未记录·自动选择"
        case .recordedAccountNeedsVerification:
            return "记录账号需重新验证"
        case .recordedAccountMissing:
            return "记录账号已失效"
        case .noSelectableAccount:
            return "尚无可用 Apple ID"
        }
    }

    private var certificateStatus: String {
        switch viewModel.localCertificateAvailability(for: app) {
        case .ready: "可用"
        case .needsFullResign: "需重签"
        case .undetermined: "待核验"
        }
    }

    private var certificateStatusColor: Color {
        switch viewModel.localCertificateAvailability(for: app) {
        case .ready: .sealSuccess
        case .needsFullResign: .sealWarning
        case .undetermined: .sealTextSecondary
        }
    }

    private var bundleIDSummary: String {
        app.mappedBundleIdentifier ?? app.preferredBundleIdentifier ?? app.originalBundleIdentifier
    }

    private var profileStatus: ProfileDisplayStatus {
        AppSigningPresentationHelpers.profileStatus(for: app)
    }

    private var profileStatusSummary: String {
        profileStatus == .available ? "有效" : profileStatus.title
    }

    private var profileStatusColor: Color {
        color(for: profileStatus.tone)
    }

    private var expirySummary: String {
        guard let date = AppSigningPresentationHelpers.profileExpirationDate(for: app) else { return "未记录" }
        return SealSettingsDateFormatter.string(from: date)
    }

    private var expiryColor: Color {
        color(for: profileStatus.tone)
    }

    private func color(for tone: AppValidityTone) -> Color {
        switch tone {
        case .success: .sealSuccess
        case .warning: .sealWarning
        case .danger: .sealDanger
        case .neutral: .sealTextSecondary
        }
    }
}
