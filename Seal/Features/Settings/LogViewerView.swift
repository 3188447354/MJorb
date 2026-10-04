import SwiftUI
import UniformTypeIdentifiers

/// 日志查看页：只显示人话卡片，不显示原始日志。
/// 导出按钮在右上角（毛玻璃圆按钮，无文字）。
struct LogViewerView: View {
    @State private var rounds: [LogRound] = []
    @State private var isExporting = false
    @State private var exportURL: URL?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if rounds.isEmpty {
                    Text("暂无日志")
                        .foregroundColor(.secondary)
                        .padding(.top, 40)
                } else {
                    ForEach(rounds) { round in
                        RoundCard(round: round)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: exportLogs) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.accentColor)
                        .frame(width: 36, height: 36)
                        .background(glassBackground)
                        .clipShape(Circle())
                }
            }
        }
        .task {
            await loadRounds()
        }
        .sheet(isPresented: $isExporting) {
            if let url = exportURL {
                ShareSheet(activityItems: [url])
            }
        }
    }

    @ViewBuilder
    private var glassBackground: some View {
        if #available(iOS 26.0, *) {
            // iOS 26 Liquid Glass
            Color.clear
                .glassEffect(.regular, in: Circle())
        } else {
            // 低版本降级：半透明模糊
            Color.white.opacity(0.4)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private func loadRounds() async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let logURL = docs?.appendingPathComponent("Seal-log.txt")
        guard let url = logURL,
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            return
        }
        let parsed = LogRound.parse(from: text)
        await MainActor.run {
            // 最新的在前面，最多显示 50 轮
            rounds = Array(parsed.suffix(50).reversed())
        }
    }

    private func exportLogs() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let logURL = docs?.appendingPathComponent("Seal-log.txt")
        if let url = logURL, FileManager.default.fileExists(atPath: url.path) {
            exportURL = url
            isExporting = true
        }
    }
}

/// 一轮续签的人话卡片数据
struct LogRound: Identifiable {
    let id = UUID()
    let title: String      // "第4轮 · 23:36:39 · 手动 · 3个App"
    let items: [LogRoundItem]
    let footer: String     // "共用6.6秒 · 3/3 成功"

    struct LogRoundItem: Identifiable {
        let id = UUID()
        let succeeded: Bool
        let text: String       // "LiveContainer 成功，用了5.9秒"
        let reason: String?    // 失败原因（人话）
    }

    /// 从日志文本解析轮次块（━ 分隔）
    static func parse(from text: String) -> [LogRound] {
        var rounds: [LogRound] = []
        var currentLines: [String] = []
        var inBlock = false

        for line in text.components(separatedBy: "\n") {
            // 日志行格式：时间 级别 分类 消息，取消息部分
            // 简化：直接找 ▶/✓/✗/■/原因 行
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 提取消息部分（去掉时间戳前缀）
            let message = extractMessage(from: line)

            if message.hasPrefix("━") {
                if inBlock && !currentLines.isEmpty {
                    if let round = buildRound(from: currentLines) {
                        rounds.append(round)
                    }
                    currentLines = []
                }
                inBlock.toggle()
                continue
            }
            if inBlock {
                currentLines.append(message)
            }
        }
        return rounds
    }

    private static func extractMessage(from line: String) -> String {
        // 日志格式：2026-10-05 00:33:19  信息  系统  [CODE] 消息
        // 轮次总结行是直接写入的，可能没有标准前缀，尽量提取
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // 如果包含 ▶/✓/✗/■/─/━，直接返回该部分
        for marker in ["▶", "✓", "✗", "○", "◷", "■", "─", "━"] {
            if let range = trimmed.range(of: marker) {
                return String(trimmed[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        // 原因行
        if trimmed.contains("原因：") {
            if let range = trimmed.range(of: "原因：") {
                return "原因：" + String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private static func buildRound(from lines: [String]) -> LogRound? {
        var title = ""
        var items: [LogRoundItem] = []
        var footer = ""
        var pendingReason: String?

        for line in lines {
            if line.hasPrefix("▶") {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("✓") {
                let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                items.append(LogRoundItem(succeeded: true, text: text, reason: nil))
            } else if line.hasPrefix("✗") {
                let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                items.append(LogRoundItem(succeeded: false, text: text, reason: pendingReason))
                pendingReason = nil
            } else if line.hasPrefix("○") || line.hasPrefix("◷") {
                let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                items.append(LogRoundItem(succeeded: true, text: text, reason: nil))
            } else if line.hasPrefix("原因：") {
                pendingReason = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                // 关联到最后一个失败项
                if let last = items.last, !last.succeeded {
                    items[items.count - 1] = LogRoundItem(
                        succeeded: false,
                        text: last.text,
                        reason: pendingReason
                    )
                    pendingReason = nil
                }
            } else if line.hasPrefix("■") {
                footer = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            // 跳过 ─ 分隔线和 → 指引行
        }

        guard !title.isEmpty else { return nil }
        return LogRound(title: title, items: items, footer: footer)
    }
}

/// 轮次卡片
struct RoundCard: View {
    let round: LogRound

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(round.title)
                .font(.system(size: 15, weight: .semibold))

            ForEach(round.items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.succeeded ? "✓" : "✗")
                            .foregroundColor(item.succeeded ? .green : .red)
                            .font(.system(size: 14, weight: .medium))
                        Text(item.text)
                            .font(.system(size: 14))
                            .foregroundColor(item.succeeded ? .primary : .red)
                    }
                    if let reason = item.reason, !reason.isEmpty {
                        Text("原因：" + reason)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .padding(.leading, 20)
                    }
                    if !item.succeeded {
                        Text("查看解决办法 →")
                            .font(.system(size: 13))
                            .foregroundColor(.accentColor)
                            .padding(.leading, 20)
                    }
                }
            }

            if !round.footer.isEmpty {
                Divider()
                Text(round.footer)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(round.items.allSatisfy(\.succeeded) ? .primary : .red)
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
