import SwiftUI
import UIKit
import PhotosUI

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
    /// 用户选的自定义图标（nil = 使用原图）。
    let onIconSelected: (Data?) -> Void

    @State private var didTapPrimaryAction = false
    @State private var showSameVersionConfirm = false
    @State private var showDowngradeConfirm = false
    @State private var isIconActionsPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var customIconData: Data?

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
                VStack(spacing: 16) {
                    Button {
                        guard showsProgress == false else { return }
                        // 版本检查：根据结果决定是否直接导入还是弹确认
                        switch draft.versionCheck {
                        case .alreadyLatest:
                            // 已是最新，不允许导入（按钮已禁用，这里兜底）
                            return
                        case .sameVersionDifferentContent:
                            showSameVersionConfirm = true
                        case .downgrade, .buildDowngrade:
                            showDowngradeConfirm = true
                        case .upgrade, .buildUpgrade, .newApp:
                            didTapPrimaryAction = true
                            onPrimaryAction()
                        }
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
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundColor(Color.sealAccent)
                            .disabled(showsProgress)
                            .accessibilityIdentifier("import-confirmation-new-copy")
                    }

                    Button("取消导入", action: onCancel)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundColor(Color.sealTextSecondary)
                        .disabled(isCommitting)
            }
        }
        .interactiveDismissDisabled(showsProgress)
        .accessibilityIdentifier("import-confirmation")
        // 同版本不同内容确认
        .alert("内容不同，是否覆盖？", isPresented: $showSameVersionConfirm) {
            Button("取消", role: .cancel) {}
            Button("覆盖", role: .destructive) {
                didTapPrimaryAction = true
                onPrimaryAction()
            }
        } message: {
            if case .sameVersionDifferentContent(let version) = draft.versionCheck {
                Text("已安装版本 \(version)，新包版本号相同但内容不同，可能是修改过的包。")
            }
        }
        // 降级警告
        .alert("确定要降级吗？", isPresented: $showDowngradeConfirm) {
            Button("取消", role: .cancel) {}
            Button("继续降级", role: .destructive) {
                didTapPrimaryAction = true
                onPrimaryAction()
            }
        } message: {
            switch draft.versionCheck {
            case .downgrade(let oldVersion, let newVersion):
                Text("当前已安装 \(oldVersion)，新包是旧版本 \(newVersion)，降级可能导致数据丢失。")
            case .buildDowngrade(let oldBuild, let newBuild, let version):
                Text("当前已安装 v\(version) build \(oldBuild)，新包是 build \(newBuild)，降级可能导致数据丢失。")
            default:
                Text("降级可能导致数据丢失。")
            }
        }
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
        return isOverwriteUpdate ? "覆盖更新" : "导入应用"
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
            Button {
                isIconActionsPresented = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("App 图标")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    Text(customIconData == nil ? "使用原图" : "已自定义")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color.sealTextSecondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Color.sealTextSecondary)
                }
                .frame(minHeight: 54)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("import-summary-icon")
            Divider().padding(.leading, 16)
            summaryRow("Bundle ID", draft.parsedIPA.bundleIdentifier, monospaced: true)
                .accessibilityIdentifier("import-summary-bundle-id")
                .accessibilityValue(draft.parsedIPA.bundleIdentifier)
            Divider().padding(.leading, 16)
            summaryRow("附加组件", extensionSummary)
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
        .sheet(isPresented: $isIconActionsPresented) {
            AppIconSelectionSheet { action in
                isIconActionsPresented = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(220))
                    switch action {
                    case .photos:
                        isPhotoPickerPresented = true
                    case .files:
                        // 导入抽屉里暂只支持相册，文件入口在签名页
                        isPhotoPickerPresented = true
                    case .original:
                        customIconData = nil
                        onIconSelected(nil)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { item in
            guard let item else { return }
            Task {
                defer { selectedPhotoItem = nil }
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                await MainActor.run {
                    customIconData = data
                    onIconSelected(data)
                }
            }
        }
    }

    private func overwriteSummary(_ existing: AppRecord) -> String {
        switch draft.versionCheck {
        case .buildUpgrade(let oldBuild, let newBuild, let version):
            return "覆盖更新「\(existing.displayName)」（v\(version) build \(oldBuild) → build \(newBuild)）"
        case .buildDowngrade(let oldBuild, let newBuild, let version):
            return "降级「\(existing.displayName)」（v\(version) build \(oldBuild) → build \(newBuild)）"
        default:
            return "覆盖更新「\(existing.displayName)」（v\(existing.version) → v\(draft.parsedIPA.version)）"
        }
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
        isOverwriteUpdate ? "将替换已安装的应用" : "可导入"
    }
}
