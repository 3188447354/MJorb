import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 日志清空通知：LogViewerView 发出，SealLogStore 持有者监听并清空内存缓存
/// 续签完成通知：AppsViewModel 发出，AppContainer 监听并停止后台保活（省电）
extension Notification.Name {
    static let sealClearLogs = Notification.Name("sealClearLogs")
    static let sealRenewalCompleted = Notification.Name("sealRenewalCompleted")
    /// Seal 自身记录更新完成（自安装重启后的结算）：应用页收到后刷新列表，
    /// "有新版本待安装"标签自动消失，不用手动切页面。
    static let sealSelfRecordUpdated = Notification.Name("sealSelfRecordUpdated")
}

/// 日志查看页：只显示人话卡片，不显示原始日志。
/// 导出按钮在右上角（毛玻璃圆按钮，无文字）。
struct LogViewerView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var rounds: [LogRound] = []
    @State private var exportDocument: LogExportDocument?
    @State private var showClearConfirm = false
    @State private var selectedError: LogRound.LogRoundItem?
    @State private var selectedErrorHelp: ErrorKnowledgeEntry?
    @State private var exportFailure: ImportFailure?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if rounds.isEmpty {
                    Text("暂无日志")
                        .foregroundColor(.secondary)
                        .padding(.top, 40)
                } else {
                    ForEach(rounds) { round in
                        RoundCard(round: round) { item in
                            selectedError = item
                        }
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
                    let info = (err.code.map { "错误码：\($0)\n" } ?? "")
                        + err.text + (err.reason.map { "\n原因：\($0)" } ?? "")
                    UIPasteboard.general.string = info
                }
            }
            Button("查看解决办法") {
                if let err = selectedError {
                    selectedErrorHelp = ErrorKnowledgeStore.bundled().help(for: err.code ?? "SEAL-LOG-UNKNOWN")
                }
            }
        } message: {
            if let err = selectedError {
                Text((err.reason ?? "暂无具体解决办法，可复制错误信息到社群求助。"))
            }
        }
        .alert(item: $exportFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text("\(failure.reason)\n\n\(failure.recovery)"),
                dismissButton: .default(Text("好的"))
            )
        }
        .task {
            await loadRounds()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sealRenewalCompleted)) { _ in
            Task { await loadRounds() }
        }
        .sheet(item: $exportDocument) { document in
            ShareSheet(activityItems: [document.url])
        }
        .sheet(item: $selectedErrorHelp) { entry in
            NavigationStack {
                ErrorHelpView(entry: entry)
            }
        }
    }

    private func loadRounds() async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let logURL = docs?.appendingPathComponent("Seal-log.txt")
        guard let url = logURL,
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            // 文件不存在或为空时清空显示，避免显示过期缓存
            await MainActor.run { rounds = [] }
            return
        }
        let parsed = LogRound.parse(from: text)
        await MainActor.run {
            // 日志文件是最新的在前面，取前 50 轮直接显示（不反转）
            rounds = Array(parsed.prefix(50))
        }
    }

    private func exportLogs() {
        Task {
            do {
                let url = try await viewModel.materializeLogExport()
                await MainActor.run {
                    guard let document = LogExportDocument(url: url) else {
                        exportFailure = ImportFailure(
                            title: "无法导出日志",
                            reason: "日志文件写入后未找到。",
                            recovery: "稍后重试",
                            code: "SEAL-LOG-002"
                        )
                        return
                    }
                    exportDocument = document
                }
            } catch let failure as ImportFailure {
                await MainActor.run { exportFailure = failure }
            } catch {
                await MainActor.run {
                    exportFailure = ImportFailure(
                        title: "无法导出日志",
                        reason: error.localizedDescription,
                        recovery: "稍后重试",
                        code: "SEAL-LOG-002"
                    )
                }
            }
        }
    }

    private func clearLogs() async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let logURL = docs?.appendingPathComponent("Seal-log.txt")
        if let url = logURL {
            try? FileManager.default.removeItem(at: url)
        }
        // 通知 SealLogStore 清空内存缓存，否则下次续签写日志时旧日志会从内存镜像回来
        NotificationCenter.default.post(name: .sealClearLogs, object: nil)
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
        let code: String?      // 仅从日志提取，缺失时不猜测
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
                } else if !inBlock {
                    // 块开头：从 ━ 行的时间戳拿日期（▶ 行本身没有日期前缀）
                    currentDate = extractDate(from: line)
                }
                inBlock.toggle()
                continue
            }
            if inBlock {
                currentLines.append(message)
            }
        }
        // 收尾：文件尾部未闭合的块（崩溃/被杀时最后一轮没写完）也要拼出来，
        // 否则"死在哪一步"的那轮在日志页根本看不到。
        if inBlock && !currentLines.isEmpty {
            if let round = buildRound(from: currentLines, date: currentDate) {
                rounds.append(LogRound(
                    title: round.title + "（未完成）",
                    items: round.items,
                    footer: round.footer.isEmpty ? "App 异常退出，该轮未完成" : round.footer
                ))
            } else {
                rounds.append(LogRound(
                    title: "未完成",
                    items: [],
                    footer: "App 异常退出，最后一轮日志不完整"
                ))
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
                let message = String(trimmed[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
                if let code = errorCode(in: trimmed) {
                    return "\(message) [\(code)]"
                }
                return message
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

    private static func errorCode(in text: String) -> String? {
        let pattern = #"SEAL-[A-Z]+-[0-9]+[a-z]?"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range])
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
                items.append(LogRoundItem(succeeded: true, text: text, reason: nil, code: nil))
            } else if line.hasPrefix("✗") {
                let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                items.append(LogRoundItem(
                    succeeded: false,
                    text: text,
                    reason: pendingReason,
                    code: errorCode(in: text) ?? pendingReason.flatMap(errorCode)
                ))
                pendingReason = nil
            } else if line.hasPrefix("○") || line.hasPrefix("◷") {
                let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                items.append(LogRoundItem(succeeded: true, text: text, reason: nil, code: nil))
            } else if line.hasPrefix("原因：") {
                pendingReason = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                // 关联到最后一个失败项
                if let last = items.last, !last.succeeded {
                    items[items.count - 1] = LogRoundItem(
                        succeeded: false,
                        text: last.text,
                        reason: pendingReason,
                        code: last.code ?? pendingReason.flatMap(errorCode)
                    )
                    pendingReason = nil
                }
            } else if line.hasPrefix("■") {
                footer = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            // 跳过 ─ 分隔线和 → 指引行
        }

        guard !rawTitle.isEmpty else { return nil }
        // 日期拿不到时保留原标题，不用今天冒充（假数据）
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
            } else if let dayBefore = cal.date(byAdding: .day, value: -2, to: Date()),
                      cal.isDate(d, inSameDayAs: dayBefore) {
                dateStr = "前天"
            } else {
                let fmt = DateFormatter()
                fmt.dateFormat = "M月d日"
                dateStr = fmt.string(from: d)
            }
        } else {
            dateStr = parts[0]  // 拿不到日期就保留原样
        }

        var newParts = parts
        if parts[0].hasPrefix("第") {
            newParts[0] = dateStr
            return newParts.joined(separator: " · ")
        }
        // 单项签名/续签也采用同一张轮次卡片；保留操作名，避免它被日期替换掉。
        newParts.removeFirst()
        newParts.insert(dateStr, at: 0)
        newParts.insert(parts[0], at: 3)
        return newParts.joined(separator: " · ")
    }
}

/// 轮次卡片
struct RoundCard: View {
    let round: LogRound
    var onSelectError: (LogRound.LogRoundItem) -> Void = { _ in }

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
                            onSelectError(item)
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
