import Foundation

struct SealLogEntry: Codable, Equatable, Identifiable, Sendable {
    enum Category: String, Codable, Sendable {
        case account
        case pairing
        case signing
        case installation
        case renewal
        case system
    }

    enum Level: String, Codable, Sendable {
        case info
        case warning
        case error
    }

    let id: UUID
    let timestamp: Date
    let category: Category
    let level: Level
    let message: String
    let code: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: Category,
        level: Level = .info,
        message: String,
        code: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
        self.code = code
    }
}

extension SealLogEntry.Category {
    /// 导出文本用的中文名（两字宽，列对齐）
    var displayName: String {
        switch self {
        case .account: return "账号"
        case .pairing: return "配对"
        case .signing: return "签名"
        case .installation: return "安装"
        case .renewal: return "续签"
        case .system: return "系统"
        }
    }
}

extension SealLogEntry.Level {
    /// 导出文本用的中文名（两字宽，列对齐）
    var displayName: String {
        switch self {
        case .info: return "信息"
        case .warning: return "警告"
        case .error: return "错误"
        }
    }
}

/// 日志导出统一排版：北京时间 + 中文固定宽度栏目，便于阅读。
enum SealLogTextFormatter {
    static func exportText(_ entries: [SealLogEntry], capacity: Int = 1000, notice: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["Seal 日志 · 北京时间 · 保留最近 \(capacity) 条"]
        if let notice {
            lines.append(notice)
        }
        lines.append("")
        lines.append(contentsOf: entries.map { entry in
            let code = entry.code.map { "  [\($0)]" } ?? ""
            let time = formatter.string(from: entry.timestamp)
            return "\(time)  \(entry.level.displayName)  \(entry.category.displayName)\(code)  \(entry.message)"
        })
        return lines.joined(separator: "\n")
    }
}
