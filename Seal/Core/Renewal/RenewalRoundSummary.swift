import Foundation

/// 续签触发来源（日志轮次头用）。
enum RenewalTriggerSource: String, Sendable {
    /// 用户在 App 内手动点「续签全部」/ 单项续签
    case manual
    /// 快捷指令触发（后台或前台）
    case shortcut
    /// 后台预测式续签
    case background

    var displayName: String {
        switch self {
        case .manual: "手动"
        case .shortcut: "快捷指令"
        case .background: "后台"
        }
    }
}

/// 轮次里单个 App 的结果（供轮次总结用）。
struct RenewalRoundItem: Sendable {
    enum Outcome: Sendable {
        case succeeded
        case failed
        case needsAction
        case awaitingConfirmation
    }

    let appName: String
    let outcome: Outcome
    /// 真实耗时（秒）。`processItem` 里取两个 `Date()` 算得，
    /// 约百纳秒开销，不增加续签时长（要求 8）。
    let duration: TimeInterval
    /// 失败时的诊断码（技术层用）
    let failureCode: String?
    /// 失败时的人话原因（用户层用，已是去术语文案）
    let failureReason: String?
    /// 失败时的恢复建议；为"知道了"时表示用户无法自行解决
    let failureRecovery: String?
}

/// 一轮续签的总结（人话层 + 技术层同源）。
///
/// 写入 `SealLogStore` 一条 `SEAL-RENEW-ROUND` 日志，App 内展示与导出文本
/// 都从这条解析/渲染，共用一份底层数据。
struct RenewalRoundSummary: Sendable {
    let roundNumber: Int
    let triggerSource: RenewalTriggerSource
    let startedAt: Date
    let endedAt: Date
    let items: [RenewalRoundItem]

    var totalDuration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    var succeededCount: Int { items.filter { $0.outcome == .succeeded }.count }
    var failedCount: Int { items.filter { $0.outcome == .failed }.count }
    var needsActionCount: Int { items.filter { $0.outcome == .needsAction }.count }
    var awaitingCount: Int { items.filter { $0.outcome == .awaitingConfirmation }.count }

    /// 人话层消息（用户直接看的）。
    ///
    /// 只说"成了没、用了多久、失败了为什么、找谁"，
    /// 不出现诊断码/Bundle ID 等术语；日志里不放重试按钮。
    func humanReadableMessage() -> String {
        let time = Self.timeFormatter.string(from: startedAt)
        var lines = [
            "━━━━━━━━━━━━━━━━━━━━━━━━",
            "▶ 第\(roundNumber)轮 · \(time) · \(triggerSource.displayName) · \(items.count)个App",
            "────────────────────────────────",
        ]
        for item in items {
            switch item.outcome {
            case .succeeded:
                lines.append("✓ \(item.appName) 成功，用了\(Self.formatDuration(item.duration))")
            case .failed:
                lines.append("✗ \(item.appName) 失败，用了\(Self.formatDuration(item.duration))")
                if let reason = item.failureReason, !reason.isEmpty {
                    // 原因可能含换行，逐行缩进
                    for rline in reason.split(separator: "\n") {
                        lines.append("  原因：\(rline)")
                    }
                }
                // 用户无法自行解决时（recovery 只是"知道了"），指引找作者
                let recovery = item.failureRecovery ?? ""
                let reason = item.failureReason ?? ""
                if recovery == "知道了" && !reason.contains("MJorb") {
                    lines.append("  → 将日志发给作者 MJorb")
                }
            case .needsAction:
                lines.append("○ \(item.appName) 本轮未执行")
                if let reason = item.failureReason, !reason.isEmpty {
                    for rline in reason.split(separator: "\n") {
                        lines.append("  原因：\(rline)")
                    }
                }
            case .awaitingConfirmation:
                lines.append("◷ \(item.appName) 等待新进程核验")
            }
        }
        lines.append("────────────────────────────────")
        var footer = "■ 完成 · 共用\(Self.formatDuration(totalDuration))"
        if failedCount == 0 && needsActionCount == 0 && awaitingCount == 0 {
            footer += " · \(succeededCount)/\(items.count) 成功"
        } else {
            var parts: [String] = []
            if succeededCount > 0 { parts.append("\(succeededCount)成功") }
            if failedCount > 0 { parts.append("\(failedCount)失败") }
            if needsActionCount > 0 { parts.append("\(needsActionCount)未执行") }
            if awaitingCount > 0 { parts.append("\(awaitingCount)待核验") }
            footer += " · " + parts.joined(separator: " · ")
        }
        lines.append(footer)
        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━")
        return lines.joined(separator: "\n")
    }

    /// 技术层摘要（诊断码行，供导出/排查用）。
    /// 人话层不展示这些；导出文本里跟在人话层后面。
    func technicalSummary() -> String {
        var lines: [String] = []
        for item in items {
            if let code = item.failureCode {
                lines.append("[\(code)] \(item.appName)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 格式工具

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 时长人话格式：4.2秒 / 1分23秒
    static func formatDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        if seconds < 60 {
            // 1 位小数，去掉 ".0"
            let v = (seconds * 10).rounded() / 10
            if v == v.rounded() {
                return "\(Int(v))秒"
            }
            return "\(v)秒"
        }
        let m = Int(seconds / 60)
        let s = Int(seconds.truncatingRemainder(dividingBy: 60))
        return "\(m)分\(s)秒"
    }
}
