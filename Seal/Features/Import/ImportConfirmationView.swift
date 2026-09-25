import SwiftUI
import UIKit

struct ImportConfirmationView: View {
    let draft: ImportDraft
    /// 检测到「已安装的同身份记录」时非空 ⇒ 本次可以走**覆盖更新**。
    /// 覆盖更新会替换那条记录及其 IPA，是破坏性操作 ⇒ 由用户在这里显式选择。
    let replacementCandidate: AppRecord?
    let isCommitting: Bool
    let failure: ImportFailure?
    let onCancel: () -> Void
    let onPrimaryAction: () -> Void
    /// 「新建副本（不覆盖）」：放弃覆盖更新，按原行为新建一条待签名记录。
    let onCreateCopy: () -> Void

    @State private var didTapPrimaryAction = false

    private var showsProgress: Bool {
        isCommitting || didTapPrimaryAction
    }

    private var isOverwriteUpdate: Bool {
        failure == nil && replacementCandidate != nil
    }

    var body: some View {
        SealDrawer(title: drawerTitle) {
            VStack(spacing: 18) {
                header
                if let failure {
                    failureCard(failure)
                } else {
                    summaryCard
                }
            }
            .padding(.bottom, 12)
        } footer: {
            VStack(spacing: 10) {
                Button {
                    guard showsProgress == false else { return }
                    didTapPrimaryAction = true
                    onPrimaryAction()
                } label: {
                    if showsProgress {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在导入")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text(primaryActionTitle)
                    }
                }
                .sealPrimaryAction(cornerRadius: 14)
                .disabled(showsProgress)
                .accessibilityIdentifier("import-confirmation-primary")

                if isOverwriteUpdate {
                    Button("新建副本（不覆盖）", action: onCreateCopy)
                        .sealOutlineAction(cornerRadius: 14)
                        .disabled(showsProgress)
                        .accessibilityIdentifier("import-confirmation-new-copy")
                }

                Button("取消", action: onCancel)
                    .sealOutlineAction(cornerRadius: 14)
                    .disabled(isCommitting)
            }
        }
        .interactiveDismissDisabled(showsProgress)
        .accessibilityIdentifier("import-confirmation")
        .onChange(of: isCommitting) { newValue in
            if newValue == false { didTapPrimaryAction = false }
        }
        .onChange(of: failure?.code) { _ in
            didTapPrimaryAction = false
        }
    }

    private var drawerTitle: String {
        if failure != nil { return "导入失败" }
        return isOverwriteUpdate ? "覆盖更新" : "导入 IPA"
    }

    private var primaryActionTitle: String {
        if let recovery = failure?.recovery { return recovery }
        return isOverwriteUpdate ? "覆盖更新" : "导入"
    }

    private var header: some View {
        HStack(spacing: 16) {
            appIcon
            VStack(alignment: .leading, spacing: 6) {
                Text(draft.parsedIPA.name)
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityIdentifier("import-confirmation-name")
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("v\(draft.parsedIPA.version) · \(formattedSize)")
                    .font(.system(size: 15, weight: .medium))
                    .accessibilityIdentifier("import-confirmation-version")
                    .foregroundStyle(Color.sealTextSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.72), lineWidth: 0.8)
        }
    }

    private var summaryCard: some View {
        VStack(spacing: 0) {
            summaryRow("Bundle ID", draft.parsedIPA.bundleIdentifier, monospaced: true)
                .accessibilityIdentifier("import-summary-bundle-id")
                .accessibilityValue(draft.parsedIPA.bundleIdentifier)
            Divider().padding(.leading, 16)
            summaryRow("扩展", extensionSummary)
                .accessibilityIdentifier("import-summary-extensions")
                .accessibilityValue(extensionSummary)
            Divider().padding(.leading, 16)
            if let candidate = replacementCandidate {
                summaryRow("更新方式", overwriteSummary(candidate))
                    .accessibilityIdentifier("import-summary-overwrite")
                    .accessibilityValue(overwriteSummary(candidate))
                Divider().padding(.leading, 16)
            }
            summaryRow("状态", migrationSummary)
                .accessibilityIdentifier("import-summary-compatibility")
                .accessibilityValue(migrationSummary)
        }
        .padding(.horizontal, 16)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.72), lineWidth: 0.8)
        }
    }

    private func overwriteSummary(_ existing: AppRecord) -> String {
        "覆盖更新「\(existing.displayName)」（v\(existing.version) → v\(draft.parsedIPA.version)）"
    }

    private func summaryRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: .regular, design: monospaced ? .monospaced : .default))
                .foregroundStyle(Color.sealTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 54)
    }

    private func failureCard(_ failure: ImportFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(failure.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Color.sealWarning)
            Text(failure.userMessage)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if failure.recovery.isEmpty == false {
                Text(failure.recovery)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.sealTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.72), lineWidth: 0.8)
        }
    }

    @ViewBuilder private var appIcon: some View {
        Group {
            if let data = draft.parsedIPA.iconData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .foregroundStyle(Color.sealAccent)
                    .background(Color.sealSurface)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: draft.parsedIPA.fileSize, countStyle: .file)
    }

    private var extensionSummary: String {
        draft.parsedIPA.extensions.isEmpty ? "无" : "\(draft.parsedIPA.extensions.count) 个"
    }

    private var migrationSummary: String {
        isOverwriteUpdate ? "将替换已安装记录" : "可导入"
    }
}
