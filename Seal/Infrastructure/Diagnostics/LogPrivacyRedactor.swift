import Foundation

enum LogPrivacyRedactor {
    static func redact(_ value: String) -> String {
        var redacted = value
        redacted = redactEmails(in: redacted)
        redacted = redactPhoneNumbers(in: redacted)
        redacted = redactJWTs(in: redacted)
        // PEM 私钥块必须在键值对之前处理：块里没有 `key: value` 结构，键值对规则完全盖不住。
        redacted = redactPEMBlocks(in: redacted)
        // `Authorization: Bearer <opaque>` 的凭据在 scheme 词之后，键值对只会吃掉 `Bearer` 本身。
        redacted = redactAuthorizationSchemes(in: redacted)
        redacted = redactSensitiveKeyValueFields(in: redacted)
        redacted = redactSensitiveXMLFields(in: redacted)
        redacted = redactUUIDs(in: redacted)
        redacted = redactLongIdentifiers(in: redacted)
        redacted = redactBase64Tokens(in: redacted)
        redacted = redactSecrets(in: redacted)
        return redacted
    }

    private static func redactEmails(in value: String) -> String {
        let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        return replaceMatches(in: value, pattern: pattern, options: [.caseInsensitive]) {
            AppleAccountClient.mask($0)
        }
    }

    /// 手机号 / 长数字串脱敏。
    ///
    /// ## ⚠️ 不能把 ISO 日期一起吃掉（2026-09-17 从真机日志发现）
    ///
    /// 数字与连字符都在字符类里，于是 `2026-09-17T06:38:18Z` 会被整段当成手机号，
    /// 而 `AppleAccountClient.mask` 对 6 / 8 位数字分别给出 `20****09` / `202****917`
    /// ⇒ **日志里所有 ISO 时间戳的年月都没了**。
    ///
    /// 后果不只是难看：证书的 `notBefore` / `notAfter` 相差整整一年，脱敏后几乎一模一样
    /// （只差 1 秒），看上去像「到期早于生效」，排查时差点被当成 bug 报上去。
    /// **日志是唯一的排障通道，时间戳被毁的代价很大。**
    ///
    /// 两道防线：
    /// ① 匹配**不能停在日期中间**（结尾多排除 `-` 与 `:`，否则会匹配出 `2026-09-17 14`）；
    /// ② 形状像「19xx/20xx + 合法月份（+ 合法日）」的片段一律原样返回。
    private static func redactPhoneNumbers(in value: String) -> String {
        let pattern = #"(?<![A-Za-z0-9])\+?[0-9][0-9 \-()]{5,}[0-9](?![A-Za-z0-9\-:])"#
        return replaceMatches(in: value, pattern: pattern) { match in
            guard looksLikeDateFragment(match) == false else { return match }
            return AppleAccountClient.mask(match)
        }
    }

    /// 该片段是否其实是 ISO 日期的一部分（`2026-09` / `2026-09-17`）。
    ///
    /// 收紧到「19xx/20xx + 合法月份 + 可选合法日」：真手机号几乎不可能同时满足
    /// 「4 位年份、连字符、合法月份」，所以这条**不会**放过真手机号
    /// （`1234-5678` / `1234-56` / `020-12345678` 都不算日期，照旧脱敏）。
    private static func looksLikeDateFragment(_ match: String) -> Bool {
        let pattern = #"^(?:19|20)\d{2}-(?:0[1-9]|1[0-2])(?:-(?:0[1-9]|[12]\d|3[01]))?$"#
        return match.range(of: pattern, options: .regularExpression) != nil
    }

    private static func redactJWTs(in value: String) -> String {
        let pattern = #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#
        return replaceMatches(in: value, pattern: pattern) { _ in "[redacted-jwt]" }
    }

    /// PEM 私钥块整块替换。
    ///
    /// PEM 里没有 `key: value`，`-----BEGIN PRIVATE KEY-----` 后跟的是 base64 正文，
    /// 所以键值对与 base64 规则都盖不住它（正文可能不含 `+/`，也可能被换行切开）。
    /// 必须按 `BEGIN ... END` 成对整块吃掉；`(?s)` 让 `.` 跨行匹配。
    private static func redactPEMBlocks(in value: String) -> String {
        let pattern = #"(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#
        return replaceMatches(in: value, pattern: pattern) { _ in "[redacted-private-key]" }
    }

    /// `Authorization: Bearer <opaque>` 这类 scheme + 凭据的组合。
    ///
    /// 键值对规则在 `authorization` 后面只看到一个 `Bearer` 词，于是把 `Bearer` 换成
    /// `[redacted]` 就收工了，真正的 token 原样留在日志里 —— 必须单独处理 scheme 后的凭据。
    private static func redactAuthorizationSchemes(in value: String) -> String {
        let pattern = #"(?i)\b(Bearer|Basic|Token|Digest)\s+([A-Za-z0-9\-._~+/=]{8,})"#
        return replaceMatches(in: value, pattern: pattern) { match in
            guard let separator = match.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                return "[redacted]"
            }
            return "\(match[..<separator]) [redacted]"
        }
    }

    private static func redactSensitiveKeyValueFields(in value: String) -> String {
        let keys = [
            "team(?:\\s*id)?", "serial(?:number)?", "udid", "uuid",
            "profile(?:\\s*uuid)?", "provisioning(?:Profile)?UUID",
            "jwt", "cookie", "authorization", "header", "headers",
            "authToken", "token", "password", "passwd", "dsid", "secret",
            "private[_ -]?key", "clientSecret", "sessionId", "sessionToken",
            "X-Apple-I-MD", "X-Apple-I-MD-M", "X-Apple-I-MD-RINFO",
            "pairing(?:File|Record|Data)?", "escrowBag", "hostId", "systemBUID"
        ].joined(separator: "|")
        // 三处都必须覆盖，缺一个就会明文外泄：
        // ① `"?` —— JSON 的键是带引号的（`"password":`），旧规则要求键后**紧跟** `[：:=]`，
        //    于是 `"password": "..."` 整条都不匹配，JSON 日志里的凭据从未被脱敏过；
        // ② `"..."` 带引号的值 —— JSON 值可以含空格，旧的 `[^\s,;\]\}]+` 会在第一个空格处
        //    截断，`"password": "my secret"` 只脱敏成 `[redacted] secret"`，后半截外泄；
        // ③ 裸值 —— 到空白/分隔符为止。
        let pattern = #"(?i)(\b(?:"# + keys + #")\b"?\s*[：:=]\s*)("(?:[^"\\]|\\.)*"|[^\s,;\]\}]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regex.matches(in: value, range: nsRange).reversed()
        var result = value
        for match in matches {
            guard match.numberOfRanges >= 3,
                  let fullRange = Range(match.range(at: 0), in: result),
                  let prefixRange = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(fullRange, with: "\(result[prefixRange])[redacted]")
        }
        return result
    }

    private static func redactSensitiveXMLFields(in value: String) -> String {
        let pattern = #"(?is)(<key>\s*(?:UDID|UUID|SerialNumber|TeamID|ProfileUUID|Authorization|Cookie|Token|Password|EscrowBag|HostID|SystemBUID)\s*</key>\s*<string>)[^<]*(</string>)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regex.matches(in: value, range: nsRange).reversed()
        var result = value
        for match in matches {
            guard match.numberOfRanges >= 3,
                  let fullRange = Range(match.range(at: 0), in: result),
                  let prefixRange = Range(match.range(at: 1), in: result),
                  let suffixRange = Range(match.range(at: 2), in: result) else { continue }
            result.replaceSubrange(fullRange, with: "\(result[prefixRange])[redacted]\(result[suffixRange])")
        }
        return result
    }

    private static func redactUUIDs(in value: String) -> String {
        let pattern = #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#
        return replaceMatches(in: value, pattern: pattern) { match in
            "\(match.prefix(8))…[uuid]"
        }
    }

    private static func redactLongIdentifiers(in value: String) -> String {
        // Covers certificate fingerprints, device identifiers and opaque Apple IDs.
        let pattern = #"\b[A-Fa-f0-9]{16,}\b"#
        return replaceMatches(in: value, pattern: pattern) { match in
            guard match.count > 8 else { return match }
            return "\(match.prefix(8))…\(match.suffix(4))"
        }
    }

    private static func redactBase64Tokens(in value: String) -> String {
        // Require at least one Base64 punctuation character to avoid masking normal prose.
        let pattern = #"(?<![A-Za-z0-9])[A-Za-z0-9]{16,}[+/][A-Za-z0-9+/]{15,}={0,2}(?![A-Za-z0-9])"#
        return replaceMatches(in: value, pattern: pattern) { _ in "[redacted-base64]" }
    }

    private static func redactSecrets(in value: String) -> String {
        let pattern = #"(?i)(authToken|token|password|dsid|secret|private_key)\s*[:=]\s*[^\s,;]+"#
        return replaceMatches(in: value, pattern: pattern) { match in
            guard let separator = match.firstIndex(where: { $0 == ":" || $0 == "=" }) else {
                return "[redacted]"
            }
            return "\(match[..<separator])\(match[separator]) [redacted]"
        }
    }

    private static func replaceMatches(
        in value: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return value
        }
        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regex.matches(in: value, options: [], range: nsRange).reversed()
        var result = value
        for match in matches {
            guard let range = Range(match.range, in: result) else { continue }
            let replacement = transform(String(result[range]))
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}
