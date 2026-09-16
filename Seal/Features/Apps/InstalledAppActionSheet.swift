import SwiftUI
import UIKit

struct InstalledAppActionSheet: View {
    let app: AppRecord
    @ObservedObject var viewModel: AppsViewModel
    let onRenew: (UUID?) -> Void
    let onShowDetail: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedAccountID: UUID?

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
                    onRenew(selectedAccountID)
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
            accountPickerRow
            Divider().padding(.leading, 14)
            metadataValueRow("证书序列号", certificateSerialSummary)
            Divider().padding(.leading, 14)
            metadataValueRow("描述文件", AppSigningPresentationHelpers.profileUUIDText(for: app))
            Divider().padding(.leading, 14)
            metadataRow("有效期至", expirySummary, valueColor: expiryColor)
            Divider().padding(.leading, 14)
            metadataRow("Bundle ID", bundleIDSummary, usesMiddleTruncation: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .glassSurface(cornerRadius: 18)
    }

    /// 长标识（证书序列号 / 描述文件 UUID）专用行：值独占一行、灰色等宽、可长按选中。
    /// 与「应用详情」页同一套呈现，避免同一信息在不同页面一个被截断、一个能看全。
    private func metadataValueRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.sealTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
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

    private var accountPickerRow: some View {
        Menu {
            Button("自动选择") { selectedAccountID = nil }
            ForEach(selectableAccounts, id: \.id) { account in
                Button {
                    selectedAccountID = account.id
                } label: {
                    Label(
                        title: { Text("\(viewModel.fullEmail(for: account)) · \(account.teamID)") },
                        icon: { Image(systemName: selectedAccountID == account.id ? "checkmark" : "") }
                    )
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("签名账户")
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
                Spacer(minLength: 12)
                Text(accountSummary)
                    .foregroundStyle(accountSummaryColor)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .allowsTightening(true)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var selectableAccounts: [AppleAccountRecord] {
        viewModel.accounts.filter { AccountAvailabilityPolicy.isSelectable($0) }
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

    private var accountSummary: String {
        if let selectedAccountID,
           let account = viewModel.accounts.first(where: { $0.id == selectedAccountID }) {
            return viewModel.fullEmail(for: account)
        }
        if let account = viewModel.accounts.first(where: { $0.id == app.accountID }) {
            return viewModel.fullEmail(for: account)
        }
        return "未记录·自动选择"
    }

    private var accountSummaryColor: Color {
        if selectedAccountID != nil { return .primary }
        if app.accountID != nil { return Color.sealTextSecondary }
        return .secondary
    }

    /// 完整证书序列号（不再用「可用」占位）：与详情页 / 签名进度页同源同 helper。
    private var certificateSerialSummary: String {
        if let serial = app.certificateSerialNumber, serial.isEmpty == false {
            return AppSigningPresentationHelpers.certificateSerialText(serial: serial)
        }
        if let serial = app.signingTargets
            .flatMap(\.certificateSerialNumbers)
            .first(where: { $0.isEmpty == false }) {
            return AppSigningPresentationHelpers.certificateSerialText(serial: serial)
        }
        return "未准备"
    }

    private var bundleIDSummary: String {
        app.mappedBundleIdentifier ?? app.preferredBundleIdentifier ?? app.originalBundleIdentifier
    }

    private var profileStatus: ProfileDisplayStatus {
        AppSigningPresentationHelpers.profileStatus(for: app)
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
