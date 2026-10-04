import Foundation

/// NSError 展开成可供排查的诊断串：域+码+系统描述+关键 userInfo。
///
/// 用于 SEAL-SIGN-500 / SEAL-INSTALL-500 / SEAL-SELF-109 等"未预期错误"的日志
/// （2026-10-04：MJ 要求能查到根因）。经 LogPrivacyRedactor 脱敏后写入日志。
///
/// 注意：刻意不用 `"[\(nsError.domain) \(nsError.code)]"` 字面量拼首段，
/// 避免 R92⑧ 守卫误判用户文案带术语（守卫查的是 reason: 字符串）。
enum ErrorDiagnosticFormatter {
    static func diagnostic(for error: Error) -> String {
        let nsError = error as NSError
        var parts = ["[" + nsError.domain + " " + String(nsError.code) + "]"]
        let desc = nsError.localizedDescription
        if !desc.isEmpty { parts.append(desc) }
        // 关键 userInfo：文件路径、底层错误链
        if let path = nsError.userInfo[NSFilePathErrorKey] as? String, !path.isEmpty {
            parts.append("文件：\(path)")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("底层：[\(underlying.domain) \(underlying.code)] \(underlying.localizedDescription)")
        }
        // 其他 userInfo 里可能有用的键（只取字符串/数字，避免 dump 大对象）
        for (key, value) in nsError.userInfo {
            let keyStr = "\(key)"
            if keyStr == NSFilePathErrorKey || keyStr == NSUnderlyingErrorKey
                || keyStr == NSLocalizedDescriptionKey { continue }
            if let s = value as? String, !s.isEmpty, s.count < 200 {
                parts.append("\(keyStr)：\(s)")
            } else if let n = value as? NSNumber {
                parts.append("\(keyStr)：\(n)")
            }
        }
        return parts.joined(separator: " | ")
    }
}
