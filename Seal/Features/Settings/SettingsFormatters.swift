import Foundation

extension Int64 {
    var sealFormattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

enum SealSettingsDateFormatter {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        // 有效期必须精确到秒（2026-09-25 用户要求）。免费账号只有 7 天寿命，
        // 同一分钟内续签两次在**分钟**粒度上完全同形 —— 而「这次拿到的确实是本轮新生成的
        // 那份描述文件」正是续签后唯一要核验的事（见 `AppDetailView` 的创建时间一栏）。
        // 秒级是唯一能把它证伪的粒度；这里改一处即覆盖全部调用点。
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}

enum TeamNameDisplayFormatter {
    static func string(from name: String) -> String {
        let parts = name
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard parts.count == 2,
              parts.allSatisfy(isCJKText) else {
            return name
        }
        return "\(parts[1]) \(parts[0])"
    }

    private static func isCJKText(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }
}
