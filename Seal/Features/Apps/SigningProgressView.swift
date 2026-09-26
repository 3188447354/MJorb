import Foundation
import SwiftUI
import UIKit

struct SigningProgressView: View {
    @ObservedObject var viewModel: AppsViewModel
    let onFinish: (SigningCompletionMode) -> Void
    @Environment(\.dismiss) private var dismiss
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
        // ⚠️ 2026-09-19：逐帧时钟**不再包住整张卡片**。
        //
        // 旧写法是 `TimelineView(.animation(1/30))` 套 `runningBody`，于是每帧都要重算
        // App 身份行、运行时卡片、所有文案判断 —— 一张弹窗卡片里最贵的东西被按 30 次/秒
        // 重做。现在时钟只留给两个叶子：进度环（转弧时）与阶段轨道（格内爬动时），
        // 秒级信息用 1Hz（整秒本来就不需要更多帧）。
        runningBody(stage)
    }

    private func runningBody(_ stage: SigningStage) -> some View {
        let workUnits = session?.workUnits
        let realProgress = session?.installProgress
        let renewalExecutionPath = session?.renewalExecutionPath
        // ⚠️ 界面最终显示的数字**只取已确认**那一份（2026-09-19 用户明确要求「圈圈不要假预估」）：
        // 有真实信号（可数对象 / 上传字节）才给百分比，没有就退回不确定的转弧。
        let hasRealSignal = SigningProgressBudget.hasRealSignal(
            stage: stage,
            realProgress: realProgress,
            workUnits: workUnits,
            renewalExecutionPath: renewalExecutionPath
        )
        let confirmed = SigningProgressBudget.confirmedProgress(
            stage: stage,
            realProgress: realProgress,
            workUnits: workUnits,
            renewalExecutionPath: renewalExecutionPath
        )
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                progressRing(
                    stage,
                    confirmed: hasRealSignal ? confirmed : nil
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(stageTitle(for: stage))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    // 真值行：这一步在数什么（没有可数对象的阶段返回 nil，就不编一行出来）。
                    if let unitsText = stage.unitsText(workUnits) {
                        Text(unitsText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.sealAccent)
                            .monospacedDigit()
                    }
                }
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

            // 上传完成 → installd 接管，进度进入「估算」区间（`installing` 的地板是 88%，
            // 估算上界 95%，**永远不会声称装完**）。这段时间安装通道不再回报任何数值，
            // 不给说明就会被读成「卡死」（2026-09-16 真机反馈）。
            // 计时 + 扫光让「还在走」变成可见事实。
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

    /// 底部阶段轨道：标题 + 五格。五格本体在 `SigningStageTrack`（批量抽屉共用同一个视图）。
    private func stageProgressSection(_ stage: SigningStage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isRenewal ? "续签进度" : "签名进度")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.sealTextSecondary)
            SigningStageTrack(
                stage: stage,
                realProgress: session?.installProgress,
                workUnits: session?.workUnits,
                renewalExecutionPath: session?.renewalExecutionPath,
                stageStartedAt: session?.stageStartedAt
            )
        }
    }

    /// 转弧相位（0–1）。周期固定 1.1 秒：比呼吸快一点，才像「在跑」而不是「在喘」。
    ///
    /// 用 `now` 直接算，而不是叠 `repeatForever` / `.animation(_:value:)` —— 叶子视图
    /// 已由 `TimelineView` 逐帧驱动，再挂一层隐式动画会互相打架（表现为转速忽快忽慢，
    /// 或者干脆停住）。
    private func spinPhase(_ now: Date) -> Double {
        let period = 1.1
        let remainder = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        return remainder / period
    }

    // ⚠️ 2026-09-26（构建 48 真机，用户要求）：进度卡片**不再显示自己的计时** ——
    // 原 `elapsedClock(_:)`（「本阶段已用时 m:ss」，1Hz 时钟）已整条移除。
    // 用户原话：「去掉那个阶段上的等待多少时间的文案，设备安装阶段的保留。」
    // ⇒ 设备安装阶段（`.installing` / `.verifying`）仍由 `InstallWaitNote` 报
    //   「设备正在安装… · 已等待 m:ss」（见 `body` 里那一处，批量抽屉共用同一视图）；
    //   其余阶段不再报时间 —— 它们有阶段名 + 五格轨道 + 转弧表达「在动」，
    //   再叠一个秒数只是把抽屉堆满，而那个数字本来也只说明「已经等了多久」，
    //   说明不了「还要等多久」。
    // 连带删除：`SigningProgressBudget.showsOwnElapsed` / `elapsedDisplayThreshold`
    //（门槛的语义已随这个视图消失），以及本文件里转调 `SigningStageTrack.elapsed` 的
    // `stageElapsed` 包装 —— 轨道格内爬动仍直接用 `SigningStageTrack.elapsed`，不受影响。

    /// 进度环：两种笔触，且**只有**这两种。
    ///
    /// - `confirmed != nil` ⇒ 有真实信号（可数对象 / 上传字节）：画已确认弧 + 环心百分比。
    ///   这种情况下值由状态变化驱动，**不需要逐帧**（`paused: true`）。
    /// - `confirmed == nil` ⇒ 没有可信信号：画一段匀速转的弧，环心**不放数字** ——
    ///   放数字就是编（2026-09-19 用户明确要求「圈圈不要假预估」）。
    ///
    /// 于是「诚实」与「别让人以为卡死」第一次不必二选一：动感由转弧承担，
    /// 数字只在有出处时出现。
    private func progressRing(_ stage: SigningStage, confirmed: Double?) -> some View {
        // Seal 自替换的安装段：不可知是**结构性**的（进程随时被 iOS 换掉），
        // 所以除了转弧还在环心留两个字，免得被读成空白故障。
        let centerLabel: String? = (confirmed == nil && stage == .installing && sealRenewal)
            ? "替换中"
            : nil
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: confirmed != nil)) { context in
            ZStack {
                Circle()
                    .stroke(Color.sealTextSecondary.opacity(0.18), lineWidth: 5)
                if let confirmed {
                    Circle()
                        .trim(from: 0, to: max(0.03, confirmed / 100))
                        .stroke(Color.sealAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(confirmed))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.sealAccent)
                        .monospacedDigit()
                } else {
                    Circle()
                        .trim(from: 0, to: 0.72)
                        .stroke(Color.sealAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(spinPhase(context.date) * 360))
                    if let centerLabel {
                        Text(centerLabel)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.sealAccent)
                    }
                }
            }
            .frame(width: 50, height: 50)
        }
        .frame(width: 50, height: 50)
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
            // 本机没有该证书私钥 ⇒ 这次续签会**完整重签并安装**（而不是只更新描述文件）。
            // 放在这里是为了让「为什么进度条在重传整包」当场有答案 ——
            // 用户 2026-09-26 的要求：文案必须与真实操作对齐，没做的事不写。
            // 用**紧凑版**文案：这一段正在跑、卡片窄，一行说清「这次为什么要重签」就够
            //（完整版留给详情页 / 操作抽屉，见 `AppSigningPresentationHelpers` 的分工说明）。
            if let note = AppSigningPresentationHelpers.localCertificateCompactNote(
                for: viewModel.localCertificateAvailability(for: session.app)
            ) {
                Divider().padding(.leading, 14)
                certificateRebuildNoteRow(note)
            }
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

    /// 「证书序列号」行下面的说明：本机没有该证书私钥 ⇒ 这一次续签会**完整重签并安装**。
    /// 与详情页 / 操作抽屉共用同一份文案真源
    ///（`AppSigningPresentationHelpers.localCertificateRebuildDetail`）。
    private func certificateRebuildNoteRow(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.sealWarning)
                .padding(.top, 1)
            Text(note)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.sealTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
    }

    /// 续签提示：Seal 自续签与普通 App 同文案；进入安装阶段后换成「正在退回主屏幕」，
    /// 让自动切后台有预期，不再要求用户手按 Home。
    private var renewalTipText: String {
        if session?.renewalExecutionPath == .profileOnly {
            return "正在更新设备端描述文件，请保持 Seal 打开。"
        }
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

    private var successTitle: String {
        guard session != nil else { return "签名完成" }
        if let renewalExecutionPath = session?.renewalExecutionPath {
            return renewalExecutionPath.successTitle
        }
        return isRenewal ? "续签并安装成功" : "签名并安装成功"
    }

    private func stageTitle(for stage: SigningStage) -> String {
        if let renewalExecutionPath = session?.renewalExecutionPath {
            return renewalExecutionPath.stageTitle(for: stage)
        }
        return stage.stageTitle(isRenewal: isRenewal)
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

    /// 配对族。`SEAL-INSTALL-703` / `707` 用的是 `SEAL-INSTALL-` 前缀，
    /// 但它们的 recovery 文案是「重新配对 / 重新连接手机并完成配对后重试」
    /// ⇒ 必须给「重新配对设备」按钮，而不是落到 `isInstallChannelFailure` 的「重新安装」。
    private func isPairingFailure(_ failure: ImportFailure) -> Bool {
        failure.code.hasPrefix("SEAL-PAIR-")
            || InstallFailureActionPolicy.pairingCodes.contains(failure.code)
    }

    private func isInstallChannelFailure(_ failure: ImportFailure) -> Bool {
        InstallFailureActionPolicy.action(for: failure.code) == .reinstall
    }

    /// 签名包「内容本身」出错（缺失/损坏/过期/设备不符/Team 不符/结构不完整），
    /// 重复安装同一个坏包不会改变结果，必须重新签名。
    ///
    /// 码集合在 `InstallFailureActionPolicy` 里显式列出：原先这里用
    /// `hasPrefix("SEAL-INSTALL-71"/"72"/"73")` 做数字区间匹配，把 738
    /// （上一笔安装仍在跑，recovery 写的是「重新启动 Seal 后再试」）与 737 也算成了
    /// 「重新签名」，一次点击即触发全量重签 + 重传，正好造出并发安装。
    private func isResignRequired(_ failure: ImportFailure) -> Bool {
        InstallFailureActionPolicy.action(for: failure.code) == .resign
    }

    /// 确定性失败：重试 / 重新安装都无法改变结果，只能按指引手动处理后重试。
    /// 按钮统一为「知道了」并关闭，不做无效重试。
    private func isNonRetryableFailure(_ failure: ImportFailure) -> Bool {
        CertificateRequestFailurePolicy.isNonRetryableFailure(failure)
            || InstallFailureActionPolicy.action(for: failure.code) == .acknowledge
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

/// 五格阶段轨道 —— 单签抽屉与批量续签抽屉**共用这一个视图**。
///
/// 抽出来不是为了省代码，是为了防漂移：每格的填充比例只能由
/// `SigningProgressBudget.bucketFill` 给出。两个抽屉各画一条、各算一份，
/// 就是本仓反复踩的「同一条规则两份实现」（改一处、另一处静默失效）。
///
/// ⚠️ 时钟**只包住这五格**，且**有真实信号时 `paused: true`** ——
/// 那时值由状态变化驱动，逐帧重算纯属浪费；没有真实信号时才让格内按时间缓慢爬
///（有界、且永不称「已完成」）。
struct SigningStageTrack: View {
    let stage: SigningStage
    let realProgress: Double?
    let workUnits: SigningWorkUnits?
    let renewalExecutionPath: RenewalExecutionPath?
    let stageStartedAt: Date?

    var body: some View {
        let hasRealSignal = SigningProgressBudget.hasRealSignal(
            stage: stage,
            realProgress: realProgress,
            workUnits: workUnits,
            renewalExecutionPath: renewalExecutionPath
        )
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: hasRealSignal)) { context in
            HStack(spacing: 6) {
                ForEach(Array(0..<SigningProgressBudget.bucketCount), id: \.self) { bucket in
                    segment(
                        bucket: bucket,
                        elapsed: Self.elapsed(at: context.date, startedAt: stageStartedAt),
                        animatesFill: hasRealSignal
                    )
                }
            }
        }
    }

    /// 进入当前阶段到现在过了多少秒。
    ///
    /// 起点为 `nil` 时返回 0（回看历史会话、或起点丢失）—— 此时进度停在阶段地板值上，
    /// 仍是个有效显示，不会出现负进度或跳变。
    static func elapsed(at now: Date, startedAt: Date?) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    @ViewBuilder
    private func segment(bucket: Int, elapsed: TimeInterval, animatesFill: Bool) -> some View {
        let segmentFill = SigningProgressBudget.bucketFill(
            bucket,
            stage: stage,
            elapsed: elapsed,
            realProgress: realProgress,
            workUnits: workUnits,
            renewalExecutionPath: renewalExecutionPath
        )
        StageSegmentCell(
            fill: segmentFill,
            isCurrent: bucket == SigningProgressBudget.plan(
                for: stage,
                renewalExecutionPath: renewalExecutionPath
            ).bucket,
            animatesFill: animatesFill
        )
    }
}

/// 轨道的一格。
///
/// 「当前格」与「已完成格」两种画法必须放在**同一个视图类型**里分支：
/// 一格从当前翻成已完成时，SwiftUI 的视图标识不变、`@State` 才活得下来，
/// 「完成闪」才放得出来 —— 早先的写法是在轨道里 `if/else` 返回两种类型，
/// 切换即重建，任何挂在旧实例上的动画都会丢。
private struct StageSegmentCell: View {
    /// 本格填充比例（0–1），唯一来源是 `SigningProgressBudget.bucketFill`。
    let fill: Double
    /// 本格是否当前阶段所在的那一格。
    let isCurrent: Bool
    /// 填充值是否**离散**跳变 —— 有真实信号时轨道的 `TimelineView` 是停着的
    ///（`paused: true`），值只在回调到来时跳一下；这种跳变才补缓动。
    /// 逐帧重算的连续值再叠一层动画只会互相拖（本文件的 `spinPhase` 写的是同一条纪律）。
    let animatesFill: Bool

    @State private var flashBrightness = 0.0

    var body: some View {
        Group {
            if isCurrent {
                // ⚠️ 不加白色扫光：它已在 2026-09-18 被用户实测否掉
                //（「横杠的煽动效果不好看」「圆点走前面中间都灰白了」——白扫过蓝，中段读成灰白）。
                // 「还在动」这件事现在由环的转弧承担（卡片上的秒数已在 2026-09-26 移除）。
                CurrentSegmentFill(fraction: CGFloat(fill))
                    // 写全 `Animation.easeOut` 而不是 `.easeOut`：三元的另一支是 `nil`，
                    // 上下文类型是 `Animation?` —— 本仓已因「可选上下文里的隐式成员」红过一次 CI。
                    .animation(animatesFill ? Animation.easeOut(duration: 0.2) : nil, value: fill)
            } else {
                Capsule()
                    .fill(fill >= 1 ? Color.sealSuccess : Color.sealTextSecondary.opacity(0.22))
                    .frame(height: 6)
                    .frame(maxWidth: .infinity)
            }
        }
        .brightness(flashBrightness)
        .onChange(of: fill >= 1) { _, isFull in
            guard isFull else {
                flashBrightness = 0
                return
            }
            // 完成闪：只在「跨到满」那一刻亮一下、0.45 秒回落。
            // 它**不推进任何数字**（绿与满都由真实完成度决定），也不是循环动效 ——
            // 循环动效属于被否掉的扫光那一类；这里放的是一次性的「又走完一截」。
            flashBrightness = 0.6
            // 峰值先上屏，回落排到下一个 runloop：同一轮里连写两次会被合并成
            // 「0 → 0」，动画从旧值 0 走到新值 0 —— 闪就没了。
            // 这里刻意用 `DispatchQueue.main.async` 而不是 `Task.sleep(16ms)`：
            // 本 App 的协作线程池常被同步 FFI 占住（见 AGENTS.md「安装」一节），
            // 定时器恢复会被推迟，而主队列这一跳是确定性的。
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.45)) { flashBrightness = 0 }
            }
        }
    }
}

/// 底部阶段轨道里「当前格」的填充。
///
/// 旧实现只填一个**写死的常数**（0.33 / 0.5 / 0.67），与真实完成度无关 ——
/// 于是这一格看起来像随机卡在某个位置，而阶段一过又整条变绿（轨道上最大的一跳）。
/// 现在比例来自 `SigningProgressBudget.bucketFill`：格内已完成阶段数 + 本阶段完成比例。
///
/// ## 扫光
///
/// 「后端在干活、界面一动不动」是这次改版要解决的头号观感问题。扫光**不推进百分比**，
/// 只表达「在动」—— 数字可能几十秒不变，但这条光一直在跑。它比任何假百分比都可信：
/// iOS 自己的不确定进度用的就是这个信号。
///
/// 只在「估算中」的当前格才画：有真实上传进度的格子本身就在动，再叠一层会像两个进度打架。
private struct CurrentSegmentFill: View {
    let fraction: CGFloat

    // ⚠️ 2026-09-19 清理：`showsSweep` / `sweepPhase` / `sweepWidth` 已删除 ——
    // 白色扫光在 2026-09-18 被移除后（用户反馈「横杠的煽动效果不好看」），
    // 这三个成员就再没有读者了 ✓。

    private static let barHeight: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let filled = max(0, geo.size.width) * clampedFraction
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.sealTextSecondary.opacity(0.22))
                Capsule()
                    .fill(Color.sealAccent)
                    .frame(width: filled, height: Self.barHeight)
                    // ⚠️ **白色扫光已移除**（2026-09-18，用户实测反馈）。
                    //
                    // 原来这里有一道 `Color.white.opacity(0.55)`、宽 18pt 的矩形扫过填充区，
                    // 目的是「数字几十秒不变时表达『在动』」。但用户看到的是：
                    // 「横杠的煽动效果不好看」「**圆点走前面中间都灰白了**」——
                    // 白色扫过蓝色，**中段就被读成灰白** ✗。
                    //
                    // 「还在动」这个信号现在由**环的转弧**承担（卡片上那行
                    // `本阶段已用时 0:20` 已在 2026-09-26 按用户要求整条移除 ——
                    // 安装阶段仍由 `InstallWaitNote` 报「已等待 m:ss」），
                    // 不再需要用视觉噪点表达。
                    .clipShape(Capsule())
            }
            .frame(height: Self.barHeight)
        }
        .frame(height: Self.barHeight)
        .frame(maxWidth: .infinity)
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
///
/// ## 为什么每一步都要写日志（2026-09-16 补）
///
/// 真机反馈「续签卡在 93%」时，这条链路**一行日志都没有** —— 于是「转场到底有没有触发」
/// 只能靠猜。现在入口、`.standDown` / `.triggerTransition` / `.waitForForeground` 三个
/// 分支、以及 `exit(0)` 兜底都各留一条，且**每条立刻 `flush()`**：`suspend` 一旦生效
/// 进程即被冻结，之后写的日志出不来。
///
/// ## 真机证据推翻了「suspend 截断安装」的假设（2026-09-17 补）
///
/// 上一条曾记着「未定论」：本类型说「iOS 只有在旧进程退出前台后才会完成替换」，
/// 而 `MinimuxerInstallChannel` 说「提前 suspend 会冻结当前连接」。查两份真机日志
/// （`Seal-log(7).txt` / `Seal-log(8).txt`，各自两次自续签）后结论变了：
///
/// - 自续签安装起点之后**没有任何安装结论**，界面永久停在 93%；
/// - 但进程**既不转场也不退出**：起点之后照常写后台日志（`[BatchDebug]`、账号同步、
///   `安装 LocalDevVPN 正常`），同一天普通 App（LiveContainer）**7 秒**装完。
///
/// 若 `suspend` 生效，进程会被冻结 ⇒ 日志停止；若 `exit(0)` 执行，进程会终止。
/// 两者都没发生 ⇒ **动作在到达 `suspend` 之前就被丢掉了**。丢掉它的正是
/// `.standDown` 分支的「立即放弃」（详见 `backgroundWaitSeconds`）。
///
/// 所以真正的因果链是：**进程不退出 ⇒ iOS 不完成替换 ⇒ installd 一直等 ⇒
/// `stageAndInstall` 一直不返回**。`suspend` 时机不是原因，`MinimuxerInstallChannel`
/// 那条注释描述的也是「别在安装返回前挂起」这个**后果**，与这里的修复方向一致。
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

    /// `.background`（用户切走了）等待「回到前台」的时长上限与轮询间隔。
    ///
    /// 旧实现在 `.background` 时**立即放弃**（`return false`），前提是「进程已让出前台，
    /// iOS 会自己完成替换」。这个前提对**覆盖安装运行中的自己**不成立：iOS 需要旧进程
    /// **终止**，而后台进程不会自己终止 —— 自续签还主动开了后台保活
    ///（真机日志「续签 Seal 自续签事务：后台保活已启动，覆盖证书、描述文件、签名和安装」），
    /// 等于主动把这个前提破坏掉了。
    ///
    /// 2026-09-16 两份真机日志是决定性证据：两次自续签（`16:53:57` / `19:43:50`）都停在 93%，
    /// 而进程**既不转场也不退出**、照常写后台日志。`.triggerTransition` 必然调 `suspend`
    /// （生效则进程冻结、日志停止），`.waitForForeground` 超时必然 `exit(0)`（进程终止）——
    /// 两者都没发生，只剩「这条分支把动作丢掉了」一种解释。
    ///
    /// 取 8 秒：覆盖「切出去看一眼再回来」的常见情形；超时后强杀 —— 此时用户在别处，
    /// 看不到闪退，而不终止进程 iOS 就永远完不成替换。
    private static let backgroundWaitSeconds: TimeInterval = 8
    private static let backgroundPollNanoseconds: UInt64 = 500_000_000

    /// 前台状态下该怎么走。抽成纯函数是为了**能单测** ——
    /// 这段判断原先直接读 `UIApplication.shared.applicationState`，没有任何测试覆盖，
    /// 而它的 `.inactive` 分支正是「Seal 自续签永久停在 93%」的根因（2026-09-16 真机反馈）；
    /// `.background` 分支则是同一现象在 2026-09-17 被坐实的**另一个**根因。
    /// 这类「错了也不会崩、只会在真机上卡死」的分支必须有测试钉住。
    ///
    /// `@MainActor`：`UIApplication` 在 Swift 6 严格并发下是主 actor 隔离的，
    /// 这里显式跟着走，避免「读它的枚举」被当成跨 actor 访问。它的调用点
    /// `waitUntilItIsTimeToExit` 与 `poll(for:waited:rounds:)` 都在主 actor 上。
    enum ReturnHomeStep: Equatable {
        /// `.background`：用户把 App 切走了（或自续签的后台保活生效）。
        ///
        /// **不再「立即放弃」** —— 见 `backgroundWaitSeconds`：先等用户回到前台走转场，
        /// 等不到就强杀。旧实现在这里直接放弃（`return false`），是 2026-09-16 真机
        /// 两次自续签都停在 93% 的直接原因：进程既不转场也不退出，永久占着前台，
        /// iOS 永远等不到替换时机。
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

    /// 一轮轮询之后该做什么。抽成纯函数是为了**能单测**：
    /// 「再等等」和「该动手了」的区别，在真机上就是「正常替换」和「永久停在 93%」，
    /// 而这段判断本身不会崩、不会编译失败、也不会跑挂失败的单测。
    enum PollOutcome: Equatable {
        /// 执行该状态对应的动作：`.active` 触发转场，其余两个走 `exit(0)` 兜底。
        case act
        /// 再等一轮。
        case wait
    }

    /// - Parameters:
    ///   - step: 当前前台状态对应的走法。
    ///   - waited: 从开始等待算起已经过了多少秒（总预算）。
    ///   - rounds: `.inactive` 已经轮询过多少轮（次数预算）。
    @MainActor
    static func poll(
        for step: ReturnHomeStep,
        waited: TimeInterval,
        rounds: Int
    ) -> PollOutcome {
        switch step {
        case .triggerTransition:
            return .act
        case .waitForForeground:
            // 瞬时失焦：进程仍占着前台，等够 3 秒（6 轮 × 0.5 秒）就自己退出 ——
            // 否则 iOS 永远等不到替换时机。这里用**次数**而不是总时长：
            // 这段等待的语义是「等系统浮层消失」，用轮数表达更贴切。
            return rounds < inactiveRetryLimit ? .wait : .act
        case .standDown:
            // 后台：等用户回到前台（最多 8 秒），等不到就强杀。
            // **绝不能像旧实现那样直接放弃** —— 不终止进程 iOS 就完不成替换，
            // 而「iOS 会自己完成替换」这个前提对覆盖安装自己并不成立。
            return waited < backgroundWaitSeconds ? .wait : .act
        }
    }

    @MainActor
    static func returnToHomeAfterSealUpload(logStore: SealLogStore? = nil) {
        Task { @MainActor in
            await log(logStore, "Seal 自替换：上传完成，1.2 秒后判断前台状态并回主屏")
            try? await Task.sleep(nanoseconds: transitionBeatNanoseconds)
            let app = UIApplication.shared
            // 这个调用**总会返回**（转场已触发，或等到该强杀为止），所以没有返回值可判。
            // 旧实现返回 `false` 表示「用户已切到后台，交给 iOS 自己替换、不强杀进程」——
            // 那条路会让进程永久占着前台，iOS 永远完不成替换（见 `backgroundWaitSeconds`）。
            await waitUntilItIsTimeToExit(app, logStore: logStore)
            // 兜底：3 秒后进程还活着，说明转场没生效（会永久停在进度页），此时才强制退出。
            // 转场成功的话进程已被挂起，这行不会执行 —— 所以不会打断退场动画。
            await log(logStore, "Seal 自替换：3 秒内进程仍存活（转场未生效），强制 exit(0)")
            try? await Task.sleep(nanoseconds: exitFallbackNanoseconds)
            exit(0)
        }
    }

    /// 阻塞到「该退出」为止：要么已经触发过转场，要么等到该强杀为止。
    ///
    /// - `.active` ⇒ 触发转场后立即返回；
    /// - `.inactive`（进程仍占着前台，此时强杀会闪退）⇒ 最多等 `inactiveRetryLimit` 轮；
    /// - `.background`（用户切走了，进程不会自己终止）⇒ 最多等 `backgroundWaitSeconds`。
    ///
    /// **刻意没有「什么都不做就返回」的路径**：旧实现把 `.background` 当成
    /// 「用户已离开、iOS 会自己完成替换」直接返回，结果进程既不转场也不退出、
    /// 永久占着前台 —— 2026-09-16 真机两次自续签都停在 93% 正是这条路径造成的。
    ///
    /// 每个分支要么 `return`、要么 `sleep`，所以既不会忙循环，也一定有界。
    @MainActor
    private static func waitUntilItIsTimeToExit(
        _ app: UIApplication,
        logStore: SealLogStore?
    ) async {
        let startedAt = Date()
        var didLogWaitingInBackground = false
        var inactiveRounds = 0
        while true {
            // 刻意不叫 `step`：`let step = step(for:)` 会让右侧解析到尚未初始化的局部变量，
            // 直接编译失败（`use of local variable 'step' before its declaration`）。
            let currentStep = step(for: app.applicationState)
            let outcome = poll(
                for: currentStep,
                waited: Date().timeIntervalSince(startedAt),
                rounds: inactiveRounds
            )
            switch currentStep {
            case .triggerTransition:
                // 这行必须在 `triggerHomeTransition` **之前**落盘：`suspend` 一旦生效，
                // 本进程就被冻结，之后写的任何日志都出不来。
                await log(logStore, "Seal 自替换：触发回主屏转场（suspend）")
                triggerHomeTransition(app)
                return
            case .standDown:
                guard outcome == .wait else {
                    await log(
                        logStore,
                        "Seal 自替换：在后台等待 \(Int(backgroundWaitSeconds)) 秒仍未回到前台，"
                        + "强制 exit(0) 让 iOS 完成替换"
                    )
                    return
                }
                // 只写一次：这里每 0.5 秒轮询一轮，逐轮都写会把日志刷满，
                // 反而把真机排查最需要的那几行淹掉。
                if didLogWaitingInBackground == false {
                    didLogWaitingInBackground = true
                    await log(
                        logStore,
                        "Seal 自替换：当前在后台，等待回到前台再触发转场"
                        + "（最多 \(Int(backgroundWaitSeconds)) 秒）"
                    )
                }
                try? await Task.sleep(nanoseconds: backgroundPollNanoseconds)
            case .waitForForeground:
                guard outcome == .wait else {
                    await log(logStore, "Seal 自替换：一直未能回到前台，走 exit(0) 兜底")
                    return
                }
                inactiveRounds += 1
                await log(logStore, "Seal 自替换：当前为瞬时失焦，等待回到前台")
                try? await Task.sleep(nanoseconds: inactiveRetryNanoseconds)
            }
        }
    }

    /// 最佳努力日志：**每条都立刻 `flush()`**。
    ///
    /// 这段代码的终点是进程被挂起（`suspend`）或被 `exit(0)` 结束 —— 留在内存缓冲里的行
    /// 会随进程一起消失。而这几行正是判定「先挂起、还是先等 installation_proxy 返回」的
    /// 唯一依据：2026-09-16 真机上自替换卡在 93% 时，**这条链路一行日志都没有**，
    /// 只能靠猜（见 `docs/qa/2026-09-16-install-stage-feedback-and-self-replacement-freeze.md` §6）。
    /// 与安装通道的 `log` 同样处理：写不进去也绝不阻断转场。
    private static func log(_ store: SealLogStore?, _ message: String) async {
        guard let store else { return }
        try? await store.append(category: .installation, message: message)
        await store.flush()
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
