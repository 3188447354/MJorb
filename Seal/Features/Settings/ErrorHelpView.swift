import SwiftUI
import UIKit

struct ErrorHelpView: View {
    let entry: ErrorKnowledgeEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.code)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(Color.sealTextSecondary)
                    Text(entry.summary)
                        .font(.title3.weight(.semibold))
                    confidenceLabel
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(Color.sealAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                if !entry.evidence.isEmpty {
                    informationSection("确认依据", items: entry.evidence, tint: .sealSuccess)
                }
                if !entry.notEvidenceOf.isEmpty {
                    informationSection("这并不能说明", items: entry.notEvidenceOf, tint: .sealWarning)
                }
                informationSection("建议操作", items: entry.actions.map(\.title), tint: .sealAccent)
                if !entry.supportData.isEmpty {
                    informationSection("需要保留的信息", items: entry.supportData, tint: .sealTextSecondary)
                }

                Button("复制诊断信息") {
                    UIPasteboard.general.string = diagnosticText
                }
                .sealOutlineAction(cornerRadius: 14)

                if let url = URL(string: "https://ios.sealsign.eu.cc/help/?q=\(entry.code)") {
                    Link(destination: url) {
                        Label("在官网查看最新帮助", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .sealPrimaryAction(cornerRadius: 14)
                }
            }
            .padding(20)
        }
        .navigationTitle("错误帮助")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
    }

    private var confidenceLabel: some View {
        Text(entry.confidenceTitle)
            .font(.caption.weight(.semibold))
            .foregroundStyle(confidenceColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(confidenceColor.opacity(0.12), in: Capsule())
    }

    private var confidenceColor: Color {
        switch entry.confidence {
        case .confirmed: .sealSuccess
        case .conditional: .sealWarning
        case .unknown: .sealTextSecondary
        }
    }

    private var diagnosticText: String {
        let limits = entry.notEvidenceOf.map { "- \($0)" }.joined(separator: "\n")
        return [entry.code, entry.summary, limits].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func informationSection(_ title: String, items: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(tint)
                        .frame(width: 6, height: 6)
                        .padding(.top, 6)
                    Text(item)
                        .font(.subheadline)
                        .foregroundStyle(Color.sealTextSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ErrorHelpLibraryView: View {
    private let entries = ErrorKnowledgeStore.bundled().entries

    var body: some View {
        List(entries) { entry in
            NavigationLink {
                ErrorHelpView(entry: entry)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.code)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(Color.sealAccent)
                    Text(entry.summary)
                        .font(.subheadline)
                        .lineLimit(2)
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(
                    "暂无离线帮助",
                    systemImage: "exclamationmark.bubble",
                    description: Text("请重新打开 Seal 后再试。")
                )
            }
        }
        .navigationTitle("错误帮助")
        .navigationBarTitleDisplayMode(.inline)
    }
}
