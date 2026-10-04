import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 日志查看页：只显示人话卡片，不显示原始日志。
/// 导出按钮在右上角（毛玻璃圆按钮，无文字）。
struct LogViewerView: View {
    @State private var rounds: [LogRound] = []
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var showClearConfirm = false
    @State private var selectedError: LogRound.LogRoundItem?

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
        .refreshable {
            await loadRounds()
        }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 8) {
                    Button(action: { showClearConfirm = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.red)
                            .frame(width: 36, height: 36)
                            .glassButton()
                    }
                    Button(action: exportLogs) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.accentColor)
                            .frame(width: 36, height: 36)
                            .glassButton()
                    }
                }
            }
        }
        .alert("清空日志？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                Task { await clearLogs() }
            }
        } message: {
            Text("将删除所有本地日志，此操作不可恢复。")
        }
        .alert("解决办法", isPresented: Binding(
            get: { selectedError != nil },
            set: { if !$0 { selectedError = nil } }
        )) {
            Button("复制错误信息") {
                if let err = selectedError {
                    let info = err.text + (err.reason.map { "\n原因：\($0)" } ?? "")
                    UIPasteboard.general.string = info
                }
            }
            Button("好的", role: .cancel) {}
        } message: {
            if let err = selectedError {
                Text((err.reason ?? "暂无具体解决办法，可复制错误信息到社群求助。"))
            }
        }
        .task {
            await loadRounds()
        }
        .sheet(isPresented: $isExporting) {
            if let url = exportURL {
                ShareSheet(activityItems: [url])
            } else {
                // 兜底：理论上不会走到（exportLogs 里已判空），避免空白抽屉
                Text("日志文件不存在")
                    .foregroundColor(.secondary)
                    .padding()
            }
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
            // 日志文件是最新的在前面，取前 50 轮直接显示（不反转）
            rounds = Array(parsed.prefix(50))
        }
    }

    private func exportLogs() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let logURL = docs?.appendingPathComponent("Seal-log.txt")
        guard let url = logURL, FileManager.default.fileExists(atPath: url.path) else {
            exportURL = nil
            isExporting = true
            return
        }
        // 复制到 tmp 目录并给个友好文件名，避免直接分享 Documents 下的文件出问题
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Seal-日志-\(formattedDate()).txt")
        try? FileManager.default.removeItem(at: tmpURL)
        do {
            try FileManager.default.copyItem(at: url, to: tmpURL)
            exportURL = tmpURL
        } catch {
            exportURL = url  // 复制失败就用原文件
        }
        isExporting = true
    }

    private func formattedDate() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return fmt.string(from: Date())
    }

    private func clearLogs() async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let logURL = docs?.appendingPathComponent("Seal-log.txt")
        if let url = logURL {
            try? FileManager.default.removeItem(at: url)
        }
        await MainActor.run {
            rounds = []
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
        var currentDate: Date?
        var inBlock = false

        for line in text.components(separatedBy: "\n") {
            let message = extractMessage(from: line)

            if message.hasPrefix("━") {
                if inBlock && !currentLines.isEmpty {
                    if let round = buildRound(from: currentLines, date: currentDate) {
                        rounds.append(round)
                    }
                    currentLines = []
                    currentDate = nil
                }
                inBlock.toggle()
                continue
            }
            if inBlock {
                // 记录第一行的日期（▶ 行的时间戳）
                if currentDate == nil, message.hasPrefix("▶") {
                    currentDate = extractDate(from: line)
                }
                currentLines.append(message)
            }
        }
        return rounds
    }

    /// 从日志行提取日期（格式：2026-10-05 00:33:19）
    private static func extractDate(from line: String) -> Date? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // 取前 19 个字符：yyyy-MM-dd HH:mm:ss
        guard trimmed.count >= 19 else { return nil }
        let dateStr = String(trimmed.prefix(19))
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return fmt.date(from: dateStr)
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

    private static func buildRound(from lines: [String], date: Date?) -> LogRound? {
        var rawTitle = ""
        var items: [LogRoundItem] = []
        var footer = ""
        var pendingReason: String?

        for line in lines {
            if line.hasPrefix("▶") {
                rawTitle = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
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

        guard !rawTitle.isEmpty else { return nil }
        let title = formatTitle(rawTitle, date: date)
        return LogRound(title: title, items: items, footer: footer)
    }

    /// 格式化标题：只把"第X轮"换成相对日期，其余不动
    /// "第4轮 · 23:36:39 · 快捷指令 · 3个App" → "今天 · 23:36:39 · 快捷指令 · 3个App"
    private static func formatTitle(_ raw: String, date: Date?) -> String {
        let parts = raw.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 4 else { return raw }

        // 相对日期替换第X轮
        let dateStr: String
        if let d = date {
            let cal = Calendar.current
            if cal.isDateInToday(d) {
                dateStr = "今天"
            } else if cal.isDateInYesterday(d) {
                dateStr = "昨天"
            } else {
                let fmt = DateFormatter()
                fmt.dateFormat = "M月d日"
                dateStr = fmt.string(from: d)
            }
        } else {
            dateStr = parts[0]  // 拿不到日期就保留原样
        }

        var newParts = parts
        newParts[0] = dateStr
        return newParts.joined(separator: " · ")
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
                        Button {
                            selectedError = item
                        } label: {
                            Text("查看解决办法 →")
                                .font(.system(size: 13))
                                .foregroundColor(.accentColor)
                        }
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

/// iOS 26 原生毛玻璃按钮：直接作用在内容上，不套多余层级，低版本自动降级
struct GlassButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

extension View {
    func glassButton() -> some View {
        modifier(GlassButtonModifier())
    }
}
