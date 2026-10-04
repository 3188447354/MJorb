import SwiftUI

struct BatchRefreshView: View {
    @ObservedObject var viewModel: AppsViewModel
    @Environment(\.dismiss) private var dismiss

    /// 每 App 历史最高环填充（item.id → fill），保证重试也不回退。
    /// 只在 View 内维护：key 是 App 的稳定 id，靠 fillSessionID 隔离不同轮次。
    @State private var maxFillByItem: [UUID: Double] = [:]
    @State private var fillSessionID: UUID?

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
                        .font(.system(size: 22, weight: .bold, design: .rounded))
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
                        if index < items.count - 1 { Divider().padding(.leading, 16) }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(16)
        .glassSurface(cornerRadius: 18)
    }

    /// 队列行（2026-10-04 小环设计）：App 名 + 右侧 26pt 状态小环。
    /// 左侧 ✓/◌ 已删（和右环重复）；右侧状态文字换成小环：
    /// 等待=灰空圈，运行=蓝环+填充%，完成=绿勾，失败=红叹号。
    private func queueRow(_ item: BatchRefreshSession.Item) -> some View {
        HStack(spacing: 12) {
            Text(item.name)
                .font(.system(size: 16, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 10)
            QueueStatusRing(state: item.state, fill: ringFill(for: item))
                .accessibilityLabel(accessibilityLabel(for: item.state))
        }
        .frame(minHeight: 54)
        .onAppear { recordMaxFill(for: item) }
        .onChange(of: item.stage) { _, newStage in
            recordMaxFill(stage: newStage, id: item.id)
        }
    }

    /// Stage → 环填充映射（设计稿 spec）：只消费 item.stage，不测量、不走网络。
    private func mappedFill(for stage: SigningStage?) -> Double {
        switch stage {
        case .preparingProfiles:
            return 0.55
        case .signing, .pushing, .installing, .verifying:
            return 0.85
        case .waitingForChannel, .preparingAccount, .preparingBundle,
             .preparingCertificate, .preparingAppID, nil:
            return 0.20
        }
    }

    /// 单调不回退的环填充：取当前映射与历史最高值的最大值。
    /// 新会话（session id 变了）还没建档时直接用当前映射，避免读到上一轮的旧值。
    private func ringFill(for item: BatchRefreshSession.Item) -> Double {
        let mapped = mappedFill(for: item.stage)
        guard viewModel.batchRefreshSession?.id == fillSessionID else { return mapped }
        return max(mapped, maxFillByItem[item.id] ?? 0)
    }

    private func recordMaxFill(for item: BatchRefreshSession.Item) {
        recordMaxFill(stage: item.stage, id: item.id)
    }

    private func recordMaxFill(stage: SigningStage?, id: UUID) {
        let sid = viewModel.batchRefreshSession?.id
        if sid != fillSessionID {
            fillSessionID = sid
            maxFillByItem = [:]
        }
        maxFillByItem[id] = max(maxFillByItem[id] ?? 0, mappedFill(for: stage))
    }

    private func accessibilityLabel(for state: BatchRefreshSession.Item.State) -> String {
        switch state {
        case .waiting: return "等待中"
        case .running, .preparingSealUpdate: return "进行中"
        case .completed, .awaitingSealConfirmation: return "已完成"
        case .failed: return "失败"
        }
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
                Button("重试全部") { viewModel.refreshAll() }
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
}

/// 队列行右侧 26pt 状态小环（2026-10-04 续签队列小环设计）。
/// 只消费 item.state + 父视图算好的 fill：等待=灰空圈，运行=蓝环+填充%，
/// 完成=绿底白勾，失败=红底白叹号。运行中带呼吸动画（设计稿），不旋转——
/// 转会让填充弧的位置失去意义。
private struct QueueStatusRing: View {
    let state: BatchRefreshSession.Item.State
    /// 0-1，仅 running 时有意义（已由父视图保证单调不回退）。
    let fill: Double

    @State private var breathing = false

    private var isRunning: Bool {
        state == .running || state == .preparingSealUpdate
    }

    var body: some View {
        ZStack {
            switch state {
            case .waiting:
                Circle()
                    .stroke(Color.sealTextSecondary.opacity(0.35), lineWidth: 3.5)
            case .running, .preparingSealUpdate:
                Circle()
                    .stroke(Color.sealAccent.opacity(0.18), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: max(0.03, min(1, fill)))
                    .stroke(Color.sealAccent, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            case .completed, .awaitingSealConfirmation:
                Circle().fill(Color.sealSuccess)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            case .failed:
                Circle().fill(Color.sealDanger)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 26, height: 26)
        .opacity(isRunning && breathing ? 0.55 : 1)
        .onAppear {
            guard isRunning else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }
}
