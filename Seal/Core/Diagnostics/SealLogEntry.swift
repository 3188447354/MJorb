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
    /// 日志文案里的业务时间统一使用北京时间，保留 ISO 8601 偏移以避免与 UTC 混淆。
    static func diagnosticTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter.string(from: date)
    }

    /// 当前构建标识，形如 `1.1.16 (91)`。
    ///
    /// **为什么构建号必须进日志表头**：`CURRENT_PROJECT_VERSION` 由
    /// `Scripts/build-unsigned-ipa.sh` 取 `GITHUB_RUN_NUMBER`，所以它**唯一对应一次 CI 构建**、
    /// 进而唯一对应一个提交。没有它就无法判断「这份日志来自哪个构建」——
    /// 2026-09-17 实际踩到：拿着一份**旧构建**的日志去分析早就改过的代码，
    /// 从日志文案反推出「修复没生效」的结论，其实那个修复根本还没进到那份构建里。
    /// 有了这一行，`grep 构建` 就能一眼定版，不用再去比对日志文案的措辞。
    static var currentBuildLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        case let (nil, build?): return "(\(build))"
        default: return "未知"
        }
    }

    static func exportText(
        _ entries: [SealLogEntry],
        capacity: Int = 1000,
        notice: String? = nil,
        buildLabel: String = SealLogTextFormatter.currentBuildLabel
    ) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = [
            "Seal 日志 · 北京时间 · 保留最近 \(capacity) 条",
            "构建 \(buildLabel) · 构建号取自 CI run number，可用于定位对应提交"
        ]
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
