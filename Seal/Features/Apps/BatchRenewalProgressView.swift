import SwiftUI

/// 批量续签进度页：面向用户的干净版，不暴露内部技术细节。
/// 只显示：应用名、状态（等待中/续签中/成功/失败）、进度条、计数。
struct BatchRenewalProgressView: View {
    @ObservedObject var viewModel: AppsViewModel
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("正在续签")
                .font(.system(size: 18, weight: .bold))
                .padding(.top, 20)
                .padding(.bottom, 4)

            if let session = viewModel.batchRefreshSession {
                Text("共 \(session.total) 个应用")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.sealTextSecondary)
                    .padding(.bottom, 20)

                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(session.items) { item in
                            renewalRow(item)
                        }
                    }
                    .padding(.horizontal, 20)
                }

                VStack(spacing: 8) {
                    ProgressView(value: Double(session.succeeded + session.failed), total: Double(session.total))
                        .progressViewStyle(.linear)
                        .padding(.horizontal, 20)

                    HStack {
                        Text("\(session.succeeded + session.failed)/\(session.total)")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.sealTextSecondary)
                            .monospacedDigit()
                        Spacer()
                        if case .completed = session.status {
                            Button("完成") { onDismiss() }
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.sealAccent)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                .padding(.top, 16)
            }
        }
        .sealScreenBackground()
    }

    private func renewalRow(_ item: BatchRefreshSession.Item) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.sealAccent.opacity(0.12))
                .frame(width: 40, height: 40)
                .overlay {
                    Text(String(item.name.prefix(1)))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.sealAccent)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 15, weight: .semibold))
                Text(statusText(item.state))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.sealTextSecondary)
            }

            Spacer(minLength: 8)

            statusIcon(item.state)
        }
        .padding(14)
        .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.sealHairline.opacity(0.58), lineWidth: 0.8)
        }
    }

    private func statusText(_ state: BatchRefreshSession.Item.State) -> String {
        switch state {
        case .waiting: return "等待中"
        case .running: return "续签中…"
        case .completed: return "续签成功"
        case .failed: return "续签失败"
        case .preparingSealUpdate: return "准备更新…"
        case .awaitingSealConfirmation: return "等待确认…"
        }
    }

    @ViewBuilder
    private func statusIcon(_ state: BatchRefreshSession.Item.State) -> some View {
        switch state {
        case .waiting:
            Image(systemName: "circle")
                .foregroundStyle(Color.sealTextSecondary)
        case .running, .preparingSealUpdate:
            ProgressView()
                .scaleEffect(0.8)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.sealSuccess)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color.sealDanger)
        case .awaitingSealConfirmation:
            Image(systemName: "hourglass")
                .foregroundStyle(Color.sealWarning)
        }
    }
}
