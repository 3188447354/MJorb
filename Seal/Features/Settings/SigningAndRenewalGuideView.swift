import SwiftUI

struct SigningAndRenewalGuideView: View {
    @State private var expandedSection: SigningGuideSection? = .requirements

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(SigningGuideSection.allCases) { section in
                    SigningGuideAccordionCard(
                        section: section,
                        isExpanded: expandedSection == section,
                        onTap: { toggle(section) }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 34)
        }
        .navigationTitle("使用指南")
        .navigationBarTitleDisplayMode(.inline)
        .sealScreenBackground(.secondary)
    }

    private func toggle(_ section: SigningGuideSection) {
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedSection = expandedSection == section ? nil : section
        }
    }
}

private enum SigningGuideSection: String, CaseIterable, Identifiable {
    case requirements
    case pairing
    case signingIPA
    case renewal
    case batchRenewal
    case automaticRenewal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .requirements: return "准备条件"
        case .pairing: return "设备配对"
        case .signingIPA: return "签名 IPA"
        case .renewal: return "续签 App"
        case .batchRenewal: return "批量续签"
        case .automaticRenewal: return "自动续签"
        }
    }

    var icon: String {
        switch self {
        case .requirements: return "checkmark.shield"
        case .pairing: return "cable.connector"
        case .signingIPA: return "app.badge"
        case .renewal: return "arrow.clockwise"
        case .batchRenewal: return "square.stack.3d.up"
        case .automaticRenewal: return "clock.arrow.circlepath"
        }
    }

    var steps: [String] {
        switch self {
        case .requirements:
            return [
                "连接 Wi-Fi",
                "打开 LocalDevVPN",
                "添加 Apple ID",
                "完成设备配对后再签名"
            ]
        case .pairing:
            return [
                "iOS 27：在 Seal 的“设备”页启动配对",
                "前往“设置 > 隐私与安全性 > 开发者模式”",
                "在“与 Seal 配对”中选择 Seal，核对配对码后确认",
                "iOS 17.4–26：用电脑配对助手导入配对文件",
                "回到“设备”页，确认 LocalDevVPN 已验证"
            ]
        case .signingIPA:
            return [
                "导入 IPA",
                "点开待签名 App",
                "确认名称、图标和 Bundle ID",
                "点击“签名并安装”",
                "首次签名会准备证书、App ID 和描述文件",
                "免费账户受设备级 3 App 限制"
            ]
        case .renewal:
            return [
                "打开已安装页",
                "点开需要续签的 App",
                "点击“立即续签”",
                "证书和设备身份匹配时只更新描述文件",
                "无法确认时自动完整重签并安装"
            ]
        case .batchRenewal:
            return [
                "打开已安装页",
                "点击“续签全部”",
                "确认本次续签结果",
                "Seal 最后续签自身，必要时会覆盖安装"
            ]
        case .automaticRenewal:
            return [
                "在“快捷指令”中添加群内提供的“Seal 自动续签”指令文件",
                "创建个人自动化并设置执行时间",
                "执行前保持 Wi-Fi 与 LocalDevVPN 可用",
                "续签成功时会有系统通知",
                "续签失败时打开 Seal 查看原因"
            ]
        }
    }
}

private struct SigningGuideAccordionCard: View {
    let section: SigningGuideSection
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                SigningGuideHeader(section: section, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                        .padding(.leading, 44)
                    ForEach(Array(section.steps.enumerated()), id: \.offset) { index, step in
                        SigningGuideStepRow(index: index, text: step)
                    }
                }
                .transition(.opacity)
            }
        }
        .background(cardBackground)
        .overlay(cardBorder)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(isExpanded ? Color.sealSurfaceElevated : Color.sealSurface)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(isExpanded ? Color.sealAccent.opacity(0.24) : Color.sealHairline.opacity(0.58), lineWidth: 0.8)
    }
}

private struct SigningGuideHeader: View {
    let section: SigningGuideSection
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: section.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.sealAccent)
                .frame(width: 30, height: 30)
                .background(Color.sealAccent.opacity(isExpanded ? 0.16 : 0.10), in: Circle())

            Text(section.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            Image(systemName: "chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.sealTextSecondary)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
        }
        .frame(minHeight: 58)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}

private struct SigningGuideStepRow: View {
    let index: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.sealAccent)
                .frame(width: 24, height: 24)
                .background(Color.sealAccent.opacity(0.12), in: Circle())

            Text(text)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
