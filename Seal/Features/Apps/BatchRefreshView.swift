import SwiftUI

struct BatchRefreshView: View {
    @ObservedObject var viewModel: AppsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // footer 常显：运行中要给出「取消续签」退出通道，不能因为「没有主操作」就整段隐藏。
        SealDrawer(title: drawerTitle, showsFooter: true) {
            VStack(alignment: .leading, spacing: 16) {
                headlineBlock
                if showsQueue { queueBlock }
                if let footerTip { tipText(footerTip) }
            }
            .padding(.bottom, 12)
        } footer: {
            action
        }
        .interactiveDismissDisabled(isRunning)
    }

    private var drawerTitle: String {
        switch viewModel.batchRefreshSession?.status {
        case .preparing, .running, .preparingSealUpdate:
            return "批量续签"
        case .completed:
            return "批量续签完成"
        case .failed:
            return "批量续签失败"
        case nil:
            return "批量续签"
        }
    }

    @ViewBuilder private var headlineBlock: some View {
        switch viewModel.batchRefreshSession?.status {
        case .preparing, nil:
            VStack(alignment: .leading, spacing: 10) {
                ProgressView().controlSize(.regular)
                Text("正在准备续签队列")
                    .font(.system(size: 18, weight: .semibold))
                Text("正在检查需要续签的 App")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.sealTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassSurface(cornerRadius: 18)
        case .running:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(progressText)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("已完成")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.sealTextSecondary)
                    Spacer()
                    ProgressView().controlSize(.small)
                }
                // 总进度条：并行时不再假装只有一个"当前 App"。
                ProgressView(value: totalProgress)
                    .progressViewStyle(.linear)
                    .tint(Color.sealAccent)
                // 阶段分布：所有并行项的实时状态汇总，文案无图标。
                if !stageDistribution.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(stageDistribution, id: \.self) { chip in
                            Text(chip)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.sealAccent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.sealAccent.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.top, 4)
                }
                uploadProgressBlock
                installWaitBlock
            }
            .padding(16)
            .glassSurface(cornerRadius: 18)
        case .preparingSealUpdate:
            VStack(alignment: .leading, spacing: 8) {
                Text("其他 App 已完成")
                    .font(.system(size: 18, weight: .semibold))
                Text("即将更新 Seal")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.sealAccent)
            }
            .padding(16)
            .glassSurface(cornerRadius: 18)
        case .completed(let result):
            VStack(alignment: .leading, spacing: 8) {
                Text(result.failed == 0 ? "全部处理完成" : "部分 App 续签失败")
                    .font(.system(size: 18, weight: .semibold))
                Text(result.failed == 0 ? "\(result.succeeded) 个 App 已续签" : "\(result.succeeded) 个成功，\(result.failed) 个失败")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.sealTextSecondary)
            }
            .padding(16)
            .glassSurface(cornerRadius: 18)
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 8) {
                Text(failure.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.sealDanger)
                Text(failure.userReason)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.sealTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .glassSurface(cornerRadius: 18)
        }
    }

    /// 上传阶段显示真实百分比。
    ///
    /// 旧实现只有一句「传输中」：一个大包（几十到几百 MB）经隧道上传要几分钟，
    /// 期间没有任何数字，用户无从判断是在传还是断了（2026-09-16 真机反馈
    /// 「续签抽屉卡在传输那没反应」）。进度来自安装通道 AFC 回调，是真实值。
    @ViewBuilder
    private var uploadProgressBlock: some View {
        if let progress = viewModel.batchRefreshSession?.currentInstallProgress,
           viewModel.batchRefreshSession?.currentStage == .pushing {
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
            .padding(.top, 2)
        }
    }

    /// 安装阶段（installd 不回进度）用计时说明替代空白。
    @ViewBuilder
    private var installWaitBlock: some View {
        if viewModel.batchRefreshSession?.currentStage == .installing
            || viewModel.batchRefreshSession?.currentStage == .verifying {
            InstallWaitNote(startedAt: viewModel.batchRefreshSession?.installStartedAt)
                .padding(.top, 2)
        }
    }

    private var queueBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("续签队列")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.sealTextSecondary)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        queueRow(item)
                        if index < items.count - 1 { Divider().padding(.leading, 24) }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(16)
        .glassSurface(cornerRadius: 18)
    }

    private func queueRow(_ item: BatchRefreshSession.Item) -> some View {
        HStack(spacing: 10) {
            Text(symbol(for: item.state))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(color(for: item.state))
                .frame(width: 16)
            Text(item.name)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 10)
            Text(title(for: item.state, isSeal: item.isSeal, stage: item.stage))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color(for: item.state))
                .lineLimit(1)
        }
        .frame(minHeight: 38)
    }

    private func tipText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.sealTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    @ViewBuilder private var action: some View {
        switch viewModel.batchRefreshSession?.status {
        case .completed(let result):
            VStack(spacing: 10) {
                if result.failed > 0 {
                    Button("重试失败项") { viewModel.refreshFailedItems() }
                        .sealOutlineAction(cornerRadius: 14)
                }
                Button("完成") { viewModel.dismissBatchRefresh(); dismiss() }
                    .sealPrimaryAction(cornerRadius: 14)
            }
        case .failed:
            VStack(spacing: 10) {
                Button("重试") { viewModel.refreshAll() }
                    .sealPrimaryAction(cornerRadius: 14)
                Button("完成") { viewModel.dismissBatchRefresh(); dismiss() }
                    .sealOutlineAction(cornerRadius: 14)
            }
        case .preparing, .running, .preparingSealUpdate:
            // 运行中必须有退出通道。旧实现把 footer 整段隐藏（`showsFooter` 直接绑到
            // `!isRunning`）且禁用了下滑关闭，于是「卡住」时用户被关在一个没有任何
            // 操作的弹窗里 —— 这正是真机反馈「怎么都没反应」里最难受的一半（2026-09-16）。
            // 取消是**软取消**：立即关闭界面，正在进行的安装会让 installd 自己跑完，
            // 结果以下一次列表刷新为准（见 cancelBatchRefresh 的说明）。
            Button("取消续签") { viewModel.cancelBatchRefresh(); dismiss() }
                .sealOutlineAction(cornerRadius: 14)
        case nil:
            EmptyView()
        }
    }

    private var items: [BatchRefreshSession.Item] {
        viewModel.batchRefreshSession?.items ?? []
    }

    private var showsQueue: Bool {
        items.isEmpty == false
    }

    private var progressText: String {
        let session = viewModel.batchRefreshSession
        return "\(completedCount) / \(session?.total ?? 0)"
    }

    /// 已终态的项数（完成 / 失败 / 待处理 / 等 Seal 新进程确认都算本轮已定）。
    /// 不用 `session.currentIndex`：它是最后完成项的队列下标，并行时完成顺序
    /// 是乱的（日志里出现过 2/3 → 3/3 → 跳回 1/3），拿它当进度会倒退。
    private var completedCount: Int {
        guard let session = viewModel.batchRefreshSession else { return 0 }
        return session.items.filter { item in
            switch item.state {
            case .completed, .failed, .waiting, .awaitingSealConfirmation:
                return true
            case .running, .preparingSealUpdate:
                return false
            }
        }.count
    }

    /// 总进度（0-1）：已完成项 / 总项。并行时不再用"当前第几个"冒充进度。
    private var totalProgress: Double {
        guard let session = viewModel.batchRefreshSession, session.total > 0 else { return 0 }
        return Double(completedCount) / Double(session.total)
    }

    /// 阶段分布文案（2026-10-04 并行 UI）：所有运行中项按阶段收敛成 3 类。
    /// profile-only 只有"拿描述文件"和"注入"两段耗时，10 个细分阶段收敛后不乱。
    /// 文案无图标（用户要求）。
    private var stageDistribution: [String] {
        guard let session = viewModel.batchRefreshSession else { return [] }
        var preparing = 0, fetchingProfiles = 0, updatingProfiles = 0
        for item in session.items where item.state == .running {
            switch item.stage {
            case .preparingProfiles:
                fetchingProfiles += 1
            case .signing, .pushing, .installing, .verifying:
                updatingProfiles += 1
            case .waitingForChannel, .preparingAccount, .preparingBundle,
                 .preparingCertificate, .preparingAppID, nil:
                preparing += 1
            }
        }
        var chips: [String] = []
        if preparing > 0 { chips.append("\(preparing) 个准备中") }
        if fetchingProfiles > 0 { chips.append("\(fetchingProfiles) 个申请描述文件中") }
        if updatingProfiles > 0 { chips.append("\(updatingProfiles) 个更新描述文件中") }
        return chips
    }

    private var footerTip: String? {
        switch viewModel.batchRefreshSession?.status {
        case .preparing, .running:
            return AppSigningPresentationHelpers.keepSealOpenTip
        case .preparingSealUpdate:
            return "更新 Seal 时会暂时回到主屏幕，安装完成后请重新打开。"
        case .failed:
            return "请确认已连接 Wi-Fi 且 LocalDevVPN 已连接后重试；若提示账号会话过期，请先在「我的」页重新验证。"
        case .completed, nil:
            return nil
        }
    }

    private var currentStageTitle: String {
        guard let session = viewModel.batchRefreshSession,
              let stage = session.currentStage else {
            return "正在续签"
        }
        return session.currentRenewalExecutionPath?.stageTitle(for: stage)
            ?? stage.stageTitle(isRenewal: true)
    }

    private var isRunning: Bool {
        switch viewModel.batchRefreshSession?.status {
        case .preparing, .running, .preparingSealUpdate:
            return true
        case .completed, .failed, nil:
            return false
        }
    }

    private func symbol(for state: BatchRefreshSession.Item.State) -> String {
        switch state {
        case .completed: return "✓"
        case .running, .preparingSealUpdate, .awaitingSealConfirmation: return "●"
        case .waiting: return "○"
        case .failed: return "!"
        }
    }

    private func title(for state: BatchRefreshSession.Item.State, isSeal: Bool, stage: SigningStage? = nil) -> String {
        switch state {
        case .completed: return isSeal ? "已更新" : "已完成"
        case .running: return runningStageTitle(stage)
        case .preparingSealUpdate: return "即将更新"
        case .awaitingSealConfirmation: return "等待新版本核验"
        case .waiting: return "等待中"
        case .failed: return "失败"
        }
    }

    private func runningStageTitle(_ stage: SigningStage?) -> String {
        switch stage {
        case .signing: return "重新签名中"
        case .pushing: return "传输中"
        case .installing, .verifying: return "安装中"
        default: return "准备中"
        }
    }

    private func color(for state: BatchRefreshSession.Item.State) -> Color {
        switch state {
        case .completed: return .sealSuccess
        case .running, .preparingSealUpdate, .awaitingSealConfirmation: return .sealAccent
        case .waiting: return .sealTextSecondary
        case .failed: return .sealDanger
        }
    }
}
