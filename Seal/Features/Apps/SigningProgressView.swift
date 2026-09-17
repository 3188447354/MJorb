import SwiftUI
import UIKit

struct SigningProgressView: View {
    @ObservedObject var viewModel: AppsViewModel
    let onFinish: (SigningCompletionMode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selfReplacementSpin = false
    /// Seal 自续签进入安装阶段后置 true：界面先做一次可感知的淡出转场并改文案，
    /// 再由 Seal 触发系统级回主屏，避免「静止数秒后瞬间消失」被误读成闪退。
    @State private var isReturningHome = false

    var body: some View {
        // footer 常显：运行中要给出「取消」退出通道。旧实现运行中 footer 为空
        // 且禁用了下滑关闭，用户被关在一个没有任何操作的弹窗里（2026-09-16 真机反馈
        // 「卡在 93% 怎么都没反应」）。
        SealDrawer(title: title, showsFooter: true) {
            VStack(spacing: 14) {
                if let app = session?.app {
                    appIdentity(app)
                }

                statusContent

                if let session {
                    signingRuntimeCard(session)
                }
            }
            .padding(.bottom, 12)
        } footer: {
            actions
        }
        .interactiveDismissDisabled(isRunning)
        // Seal 自续签=覆盖安装运行中的自己：进入 .installing（上传完成）后自动切到后台，
        // 让 iOS 用新版替换旧进程，无需人手按 Home；安装续由重新打开的新进程对账确认。
        //
        // 这里**只负责视觉**：先用 withAnimation 把「正在退回主屏幕」这一帧渲染出来，
        // 用户看到的是有交代的退场，而不是界面凭空消失。
        // 真正的「回主页」动作由 AppsViewModel.updateSigningStage 在状态层触发 ——
        // 挂在界面上的话，用户一点「取消」关掉抽屉，触发点就跟着消失了，
        // 而安装早已交给 installd，Seal 的替换会静默失败。
        .onChange(of: viewModel.signingSession?.status) { _, newStatus in
            if case .running(.installing)? = newStatus,
               viewModel.signingSession?.app.isSeal == true {
                withAnimation(.easeInOut(duration: 0.45)) {
                    isReturningHome = true
                }
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch session?.status {
        case .running(let stage):
            runningContent(stage)
        case .succeeded(let installed):
            successContent(installed)
        case .failed(let failure):
            failureContent(failure)
        case nil:
            EmptyView()
        }
    }

    private func runningContent(_ stage: SigningStage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                progressRing(stage)
                Text(stage.stageTitle(isRenewal: isRenewal))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            if stage == .pushing, let progress = session?.installProgress, progress >= 0, progress <= 1 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("正在传输到设备")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.sealTextSecondary)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.sealAccent)
                            .monospacedDigit()
                    }
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Color.sealAccent)
                }
                .padding(10)
                .background(Color.sealAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if isRenewal {
                Text(renewalTipText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.sealAccent)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(isReturningHome ? 0.72 : 1)
            }

            // 上传完成 → installd 接管，进度环停在 93%（Seal 自替换显示「替换中」）。
            // 这段时间安装通道不再回报任何数值，不给说明就会被读成「卡死」
            //（2026-09-16 真机反馈）。计时让「还在走」变成可见事实。
            if stage == .installing || stage == .verifying {
                InstallWaitNote(startedAt: session?.installStartedAt)
            }

            stageProgressSection(stage)
        }
        .padding(14)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.72), lineWidth: 0.8)
        }
    }

    private func stageProgressSection(_ stage: SigningStage) -> some View {
        let current = timelinePosition(for: stage)
        return VStack(alignment: .leading, spacing: 8) {
            Text(isRenewal ? "续签进度" : "签名进度")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.sealTextSecondary)
            HStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { index in
                    progressSegment(index: index, current: current, fraction: segmentFraction(for: stage))
                }
            }
        }
    }

    @ViewBuilder
    private func progressSegment(index: Int, current: Int, fraction: CGFloat) -> some View {
        if index < current {
            Capsule()
                .fill(Color.sealSuccess)
                .frame(height: 6)
                .frame(maxWidth: .infinity)
        } else if index == current {
            CurrentSegmentFill(fraction: fraction)
                .frame(maxWidth: .infinity)
        } else {
            Capsule()
                .fill(Color.sealTextSecondary.opacity(0.22))
                .frame(height: 6)
                .frame(maxWidth: .infinity)
        }
    }

    private func segmentFraction(for stage: SigningStage) -> CGFloat {
        switch stage {
        case .waitingForChannel: return 0.5
        case .preparingAccount: return 0.33
        case .preparingCertificate: return 0.67
        case .preparingAppID: return 0.33
        case .preparingProfiles: return 0.67
        case .signing: return 0.5
        case .pushing:
            let p = session?.installProgress ?? 0
            return 0.3 + 0.3 * CGFloat(max(0, min(1, p)))
        case .installing: return 0.8
        case .verifying: return 1.0
        }
    }

    private func progressRing(_ stage: SigningStage) -> some View {
        // Seal 自续签的 .installing 是「覆盖运行中的自己」，进度停在 93% 直到 iOS 用
        // 新版替换旧进程。这里用转圈动效给出「正在替换」反馈，而不是静止数字造成的“卡死”错觉。
        if case .installing = stage, sealRenewal {
            return AnyView(selfReplacementInstallingRing)
        }
        let progress = overallProgress(for: stage)
        return AnyView(
            ZStack {
                Circle()
                    .stroke(Color.sealTextSecondary.opacity(0.18), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.03, progress))
                    .stroke(Color.sealAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.45), value: progress)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.sealAccent)
                    .monospacedDigit()
            }
            .frame(width: 50, height: 50)
        )
    }

    private var selfReplacementInstallingRing: some View {
        ZStack {
            Circle()
                .stroke(Color.sealTextSecondary.opacity(0.18), lineWidth: 5)
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Color.sealAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(selfReplacementSpin ? 360 : 0))
                .animation(
                    .linear(duration: 0.8).repeatForever(autoreverses: false),
                    value: selfReplacementSpin
                )
                .onAppear { selfReplacementSpin = true }
            Text("替换中")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.sealAccent)
        }
        .frame(width: 50, height: 50)
    }

    private func overallProgress(for stage: SigningStage) -> CGFloat {
        switch stage {
        case .waitingForChannel: return 0.06
        case .preparingAccount: return 0.16
        case .preparingCertificate: return 0.30
        case .preparingAppID: return 0.42
        case .preparingProfiles: return 0.54
        case .signing: return 0.68
        case .pushing:
            let p = session?.installProgress ?? 0
            return 0.78 + 0.12 * CGFloat(max(0, min(1, p)))
        case .installing: return 0.93
        case .verifying: return 0.99
        }
    }

    private func successContent(_ installed: AppRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.sealSuccess)
            VStack(alignment: .leading, spacing: 3) {
                Text(successTitle)
                    .font(.system(size: 16, weight: .semibold))
                Text(expiryText(for: installed))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.sealTextSecondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func failureContent(_ failure: ImportFailure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.sealDanger)
                Text(failure.title)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            Text(userFacingReason(failure))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.sealTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // Only show recovery hint when it differs from primary action button
            let recovery = recoveryText(failure)
            if recovery.isEmpty == false, recovery != primaryRecoveryTitle(failure) {
                Text(recovery)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.sealAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.sealDanger.opacity(0.18), lineWidth: 0.8)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch session?.status {
        case .running:
            Button("取消") {
                viewModel.cancelSigning()
                dismiss()
            }
            .sealOutlineAction(cornerRadius: 14)

        case .succeeded:
            Button("完成") { finish() }
                .sealPrimaryAction(cornerRadius: 14)

        case .failed(let failure):
            if failure.code == "SEAL-APPID-DEVICELIMIT" {
                VStack(spacing: 10) {
                    Button("已用 Lara 绕过，继续安装") {
                        viewModel.continueBypassingDeviceLimit()
                    }
                    .sealPrimaryAction(cornerRadius: 14)
                    Button(primaryRecoveryTitle(failure)) {
                        performPrimaryRecovery(failure)
                    }
                    .sealOutlineAction(cornerRadius: 14)
                }
            } else {
                Button(primaryRecoveryTitle(failure)) {
                    performPrimaryRecovery(failure)
                }
                .sealPrimaryAction(cornerRadius: 14)
            }
        case nil:
            EmptyView()
        }
    }

    private func signingRuntimeCard(_ session: SigningSession) -> some View {
        VStack(spacing: 0) {
            runtimeRow("签名账户", viewModel.fullEmail(for: session.account))
            Divider().padding(.leading, 14)
            runtimeSerialRow("证书序列号", certificateDisplayName(session))
            Divider().padding(.leading, 14)
            runtimeRow("Bundle ID", runtimeBundleIdentifier(session))
        }
        .padding(.horizontal, 14)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.72), lineWidth: 0.8)
        }
    }

    private func runtimeRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, weight: .regular, design: title.contains("Bundle") ? .monospaced : .default))
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.middle)
                .layoutPriority(1)
        }
        .frame(minHeight: 42)
    }

    /// 证书序列号行：标题左、值右，同一行展示；超长中间省略（保留头尾便于核对）。
    private func runtimeSerialRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.sealTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minHeight: 42)
        .padding(.vertical, 4)
    }

    /// 续签提示：Seal 自续签与普通 App 同文案；进入安装阶段后换成「正在退回主屏幕」，
    /// 让自动切后台有预期，不再要求用户手按 Home。
    private var renewalTipText: String {
        if sealRenewal, case .running(.installing)? = session?.status {
            return AppSigningPresentationHelpers.sealReturningHomeTip
        }
        return AppSigningPresentationHelpers.keepSealOpenTip
    }

    private func certificateDisplayName(_ session: SigningSession) -> String {
        // 与详情页 AppDetailView.certificateName 共用同一个 helper，用会话真实的
        // selectedCertificateSerialNumber（签名时由 onCertificateResolved 回写）作序列号，
        // 使签名进度页与详情页展示完全同步；证书尚未确定时保持“未准备”。
        // 展示值只有序列号本身（不再带「序列号 · 」前缀），且完整不截断。
        guard let serial = session.selectedCertificateSerialNumber ?? session.account.certificateSerialNumber,
              serial.isEmpty == false else {
            return "未准备"
        }
        return AppSigningPresentationHelpers.certificateSerialText(serial: serial)
    }

    private func runtimeBundleIdentifier(_ session: SigningSession) -> String {
        if let requested = session.requestedBundleIdentifier, requested.isEmpty == false {
            return requested
        }
        return displayBundleIdentifier(session.app)
    }

    private func appIdentity(_ app: AppRecord) -> some View {
        HStack(spacing: 14) {
            appIcon(app, size: 52)
            VStack(alignment: .leading, spacing: 5) {
                Text(app.displayName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("v\(app.version) · \(app.size.sealFormattedByteCount)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.sealTextSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func displayBundleIdentifier(_ app: AppRecord) -> String {
        if app.isSeal { return app.mappedBundleIdentifier ?? app.preferredBundleIdentifier ?? app.originalBundleIdentifier }
        if app.belongsInInstalledList || app.belongsInSignedList { return app.mappedBundleIdentifier ?? app.preferredBundleIdentifier ?? app.originalBundleIdentifier }
        return app.preferredBundleIdentifier ?? app.originalBundleIdentifier
    }

    @ViewBuilder
    private func appIcon(_ app: AppRecord, size: CGFloat) -> some View {
        Group {
            if let data = viewModel.iconData[app.id], let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(11)
                    .foregroundStyle(Color.sealAccent)
                    .background(Color.sealSurface)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private var session: SigningSession? { viewModel.signingSession }
    private var isRenewal: Bool { session?.app.belongsInInstalledList == true }
    private var sealRenewal: Bool { session?.app.isSeal == true }

    private var title: String {
        switch session?.status {
        case .running: isRenewal ? "正在续签" : "正在签名"
        case .succeeded: isRenewal ? "续签完成" : "签名完成"
        case .failed: isRenewal ? "续签失败" : "签名失败"
        case nil: "签名"
        }
    }

    private var isRunning: Bool {
        if case .running = session?.status { return true }
        return false
    }

    private func timelinePosition(for stage: SigningStage) -> Int {
        switch stage {
        case .waitingForChannel: 0
        case .preparingAccount, .preparingCertificate: 1
        case .preparingAppID, .preparingProfiles: 2
        case .signing: 3
        case .pushing, .installing, .verifying: 4
        }
    }

    private var successTitle: String {
        guard session != nil else { return "签名完成" }
        return isRenewal ? "续签并安装成功" : "签名并安装成功"
    }

    private func expiryText(for installed: AppRecord) -> String {
        guard let expiryDate = installed.provisioningProfileExpirationDate ?? installed.expiryDate else {
            return "应用已安装"
        }
        return "有效期至 \(SealSettingsDateFormatter.string(from: expiryDate))"
    }

    private func primaryRecoveryTitle(_ failure: ImportFailure) -> String {
        if isNonRetryableFailure(failure) { return "知道了" }
        if failure.code == "SEAL-CERT-204e" { return "撤销并继续签名" }
        if failure.code.hasPrefix("SEAL-NET-") { return "重试" }
        if isResignRequired(failure) { return "重新签名" }
        if isInstallChannelFailure(failure) { return "重新安装" }
        if isTeamFailure(failure) { return "选择 Team" }
        if isAuthFailure(failure) { return "重新验证 Apple ID" }
        if isCertificateFailure(failure) { return "重新检查" }
        if isAppIDLimitFailure(failure) { return "知道了" }
        if isAppIDFailure(failure) || failure.code.hasPrefix("SEAL-BUNDLE-") { return "重试" }
        if isPairingFailure(failure) { return "重新配对设备" }
        if failure.code.hasPrefix("SEAL-VPN-") { return "重新检查" }
        if failure.code == "SEAL-EXT-401" { return "移除扩展并重试" }
        return "重试"
    }

    private func performPrimaryRecovery(_ failure: ImportFailure) {
        if isNonRetryableFailure(failure) {
            viewModel.dismissSigningResult()
            dismiss()
        } else if failure.code == "SEAL-CERT-204e" {
            // 一键盘活：撤销无钥匙证书 → 自动重试本次签名 → 自动重签受影响已装 App。
            viewModel.confirmCertificateSacrificeAndRetry()
        } else if failure.code.hasPrefix("SEAL-NET-") {
            viewModel.retrySigning()
        } else if isResignRequired(failure) {
            viewModel.retrySigningFromScratch()
        } else if isInstallChannelFailure(failure) {
            Task { await viewModel.retryInstallationForCurrentSigningSession() }
        } else if isTeamFailure(failure) {
            openSettings(.account)
        } else if isAuthFailure(failure) {
            openSettings(.account)
        } else if isCertificateFailure(failure) {
            viewModel.retrySigning()
        } else if isAppIDFailure(failure) || failure.code.hasPrefix("SEAL-BUNDLE-") {
            viewModel.dismissSigningResult()
            dismiss()
        } else if isPairingFailure(failure) {
            openSettings(.pairing)
        } else if failure.code.hasPrefix("SEAL-VPN-") {
            viewModel.retrySigning()
        } else if failure.code == "SEAL-EXT-401" {
            viewModel.retryWithoutExtensions()
        } else {
            viewModel.retrySigning()
        }
    }

    private func userFacingReason(_ failure: ImportFailure) -> String {
        failure.userReason
    }

    private func recoveryText(_ failure: ImportFailure) -> String {
        let recovery = failure.recovery.trimmingCharacters(in: .whitespacesAndNewlines)
        if recovery.isEmpty || recovery == "知道了" { return "" }
        return recovery
    }

    private func isTeamFailure(_ failure: ImportFailure) -> Bool {
        failure.code == "SEAL-AUTH-112" || failure.title.localizedCaseInsensitiveContains("Team 不匹配")
    }

    private func isAuthFailure(_ failure: ImportFailure) -> Bool {
        failure.code.hasPrefix("SEAL-AUTH-") || failure.code.contains("APPLE_ID")
    }

    private func isCertificateFailure(_ failure: ImportFailure) -> Bool {
        failure.code.hasPrefix("SEAL-CERT-") || failure.code.contains("CERT")
    }

    private func isAppIDFailure(_ failure: ImportFailure) -> Bool {
        failure.code.hasPrefix("SEAL-APPID-")
    }

    private func isAppIDLimitFailure(_ failure: ImportFailure) -> Bool {
        failure.code == "SEAL-APPID-301" || failure.code == "SEAL-APPID-304"
    }

    private func isPairingFailure(_ failure: ImportFailure) -> Bool {
        failure.code.hasPrefix("SEAL-PAIR-")
    }

    private func isInstallChannelFailure(_ failure: ImportFailure) -> Bool {
        failure.code.hasPrefix("SEAL-INSTALL-")
    }

    /// 签名包「内容本身」出错（缺失/损坏/过期/设备不符/Team 不符/结构不完整），
    /// 重复安装同一个坏包不会改变结果，必须重新签名。对应错误码区间：
    /// SEAL-INSTALL-700~710 = 设备/安装通道（可重装或确定性）；711~730 = 重新签名。
    private func isResignRequired(_ failure: ImportFailure) -> Bool {
        let code = failure.code
        return code.hasPrefix("SEAL-INSTALL-71")
            || code.hasPrefix("SEAL-INSTALL-72")
            || code.hasPrefix("SEAL-INSTALL-73")
    }

    /// 确定性失败：重试 / 重新安装都无法改变结果，只能按指引手动处理后重试。
    /// 按钮统一为「知道了」并关闭，不做无效重试。
    private func isNonRetryableFailure(_ failure: ImportFailure) -> Bool {
        CertificateRequestFailurePolicy.isNonRetryableFailure(failure)
            || failure.code == "SEAL-APPID-DEVICELIMIT"
            || failure.code == "SEAL-INSTALL-702l"   // 安装被 iOS 拒绝（免费账号 3 应用上限 / 完整性校验）
            || failure.code == "SEAL-INSTALL-702s"   // 设备存储空间不足
    }

    private func openSettings(_ route: SettingsRoute) {
        viewModel.dismissSigningResult()
        viewModel.openSettings(route: route)
        dismiss()
    }

    private func finish() {
        let completionMode = session?.completionMode ?? .signAndInstall
        viewModel.dismissSigningResult()
        onFinish(completionMode)
        dismiss()
    }
}

private struct CurrentSegmentFill: View {
    let fraction: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.sealTextSecondary.opacity(0.22))
                Capsule()
                    .fill(Color.sealAccent)
                    .frame(width: geo.size.width * clampedFraction)
            }
        }
        .frame(height: 6)
    }

    private var clampedFraction: CGFloat { max(0, min(1, fraction)) }
}

/// Seal 自续签的「回主屏幕」动作。
///
/// Seal 自续签 = 覆盖安装正在运行的自己：iOS 只有在旧进程退出前台后才会用新版完成替换。
/// 旧实现是「静止等 2 秒 → `perform("suspend")`」，一旦 `suspend` 在某个系统版本上不再
/// 响应就会静默什么都不做，最后由 installd 直接杀进程 —— 用户看到的就是「闪退」。
/// 现在：
///   1. UI 先渲染「正在退回主屏幕」（由 SigningProgressView 的 withAnimation 负责）；
///   2. 先看当前前台状态（见 `ReturnHomeStep`）：`.background` 说明用户已离开，
///      交给 iOS 自己完成替换；`.inactive` 是**瞬时**失焦，进程仍占着前台，必须等它恢复
///      —— 早退会连 `exit(0)` 兜底一起跳过，安装永远完不成（2026-09-16 真机：永久停在 93%）；
///   3. 触发与「按 Home」等价的系统级转场，交给系统播放退场动画；
///   4. 转场后等 3 秒，若进程仍存活（说明转场没生效）才用 `exit(0)` 兜底，
///      保证进程一定结束、iOS 才能完成替换；转场成功时进程已被挂起，不会走到这里。
/// 本类型只做「切后台 / 退出」，不碰签名、证书、自替换事务：安装结果仍由重新打开的
/// 新进程 `SelfReplacementCoordinator` 对账确认。
enum SelfInstallAutoBackground {
    /// 转场前的可感知停顿：既让 UI 的「正在退回主屏幕」渲染出来，也给 Rust 暂存落盘留余量。
    private static let transitionBeatNanoseconds: UInt64 = 1_200_000_000
    /// `exit(0)` 兜底的等待时间。取 3 秒：远长于系统退场动画（约 0.3–0.5 秒），
    /// 确保转场成功时进程早已被挂起，这段代码不会执行，不会打断动画。
    private static let exitFallbackNanoseconds: UInt64 = 3_000_000_000

    /// 等待 `.inactive`（瞬时失焦）自行恢复为 `.active` 的重试间隔与次数。
    /// 3 秒足够覆盖控制中心 / 通知横幅 / 来电浮层这类短暂遮挡。
    private static let inactiveRetryNanoseconds: UInt64 = 500_000_000
    private static let inactiveRetryLimit = 6

    /// 前台状态下该怎么走。抽成纯函数是为了**能单测** ——
    /// 这段判断原先直接读 `UIApplication.shared.applicationState`，没有任何测试覆盖，
    /// 而它的 `.inactive` 分支正是「Seal 自续签永久停在 93%」的根因（2026-09-16 真机反馈）。
    /// 这类「错了也不会崩、只会在真机上卡死」的分支必须有测试钉住。
    ///
    /// `@MainActor`：`UIApplication` 在 Swift 6 严格并发下是主 actor 隔离的，
    /// 这里显式跟着走，避免「读它的枚举」被当成跨 actor 访问。它唯一的调用点
    /// `waitUntilExitIsSafe` 本来就在主 actor 上。
    enum ReturnHomeStep: Equatable {
        /// `.background`：用户真的自己切走了，进程已让出前台，iOS 能完成替换。
        /// 不重复触发转场（避免和用户操作打架），**也不强杀进程**。
        case standDown
        /// `.active`：正常触发与「按 Home」等价的系统转场。
        case triggerTransition
        /// `.inactive`：瞬时失焦（控制中心、通知横幅、来电、App 切换器预览、系统弹窗），
        /// **进程仍在前台** —— iOS 不会完成替换，所以必须等它恢复，绝不能直接放弃。
        case waitForForeground
    }

    @MainActor
    static func step(for state: UIApplication.State) -> ReturnHomeStep {
        switch state {
        case .active:
            return .triggerTransition
        case .inactive:
            return .waitForForeground
        case .background:
            return .standDown
        @unknown default:
            // 未知状态按「还没离开前台」处理：宁可多等一轮，也不能静默放弃安装。
            return .waitForForeground
        }
    }

    @MainActor
    static func returnToHomeAfterSealUpload() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: transitionBeatNanoseconds)
            let app = UIApplication.shared
            guard await waitUntilExitIsSafe(app) else { return }
            // 兜底：3 秒后进程还活着，说明转场没生效（会永久停在进度页），此时才强制退出。
            // 转场成功的话进程已被挂起，这行不会执行 —— 所以不会打断退场动画。
            try? await Task.sleep(nanoseconds: exitFallbackNanoseconds)
            exit(0)
        }
    }

    /// 等到「可以安全退出」为止。
    ///
    /// - 返回 `false` 表示用户已把 App 切到后台，iOS 自己会完成替换，**不该强杀进程**；
    /// - 返回 `true` 表示该走 `exit(0)` 兜底：要么已经触发过转场，要么一直是 `.inactive`
    ///   （进程仍占着前台，iOS 永远等不到替换时机 —— 只能自己退出）。
    ///
    /// 旧实现把 `.inactive` 也当成「用户已离开」直接 `return`，连 `exit(0)` 兜底一起跳过，
    /// 于是安装永远完不成、界面永久停在 93%。
    @MainActor
    private static func waitUntilExitIsSafe(_ app: UIApplication) async -> Bool {
        for _ in 0...inactiveRetryLimit {
            switch step(for: app.applicationState) {
            case .standDown:
                return false
            case .triggerTransition:
                triggerHomeTransition(app)
                return true
            case .waitForForeground:
                try? await Task.sleep(nanoseconds: inactiveRetryNanoseconds)
            }
        }
        return true
    }

    /// 触发与「按 Home」等价的系统转场。`suspend` 是私有 selector：
    /// 先直接 perform，不响应时再用「借 UIControl 发消息」的经典写法兜底。
    ///
    /// **刻意不返回「是否成功」**：`UIControl.sendAction(_:to:for:)` 的返回类型是 `Void`，
    /// 不是 `Bool`，无法据其判断转场是否真的触发。早期版本按 `Bool` 用，直接编译失败
    ///（`cannot convert return expression of type 'Void' to return type 'Bool'`）。
    /// 现在的判据是「给足时间后进程是否仍存活」，见 `exitFallbackNanoseconds`。
    @MainActor
    private static func triggerHomeTransition(_ app: UIApplication) {
        let selector = NSSelectorFromString("suspend")
        if app.responds(to: selector) {
            _ = app.perform(selector)
            return
        }
        UIControl().sendAction(selector, to: app, for: nil)
    }
}
