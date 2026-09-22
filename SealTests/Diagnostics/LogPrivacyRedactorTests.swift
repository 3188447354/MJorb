import Foundation
import Testing
@testable import Seal

/// 日志脱敏的固定秘密语料。
///
/// 导出/上报的日志会离开设备，所以这里的断言一律是「**秘密不得出现在输出里**」，
/// 而不是「输出等于某个固定串」—— 脱敏器可以改实现，但不能漏掉秘密。
///
/// 语料按 `outputs/Seal_企业级发布整改方案_20260913.md` §5 点名的四类形态组织：
/// 带引号 JSON key、空格/转义、多行私钥、header。
struct LogPrivacyRedactorTests {
    private func assertNoSecret(_ input: String, _ secrets: [String]) {
        let output = LogPrivacyRedactor.redact(input)
        for secret in secrets {
            #expect(
                output.contains(secret) == false,
                "秘密「\(secret)」未被脱敏，输出：\(output)"
            )
        }
    }

    // MARK: - 带引号 JSON key + 含空格的值

    /// 旧实现的值规则是 `[^\s,;\]\}]+`，遇到空格就截断：
    /// `"password": "hunter2 with spaces"` 只会变成 `[redacted] with spaces"`，后半截明文外泄。
    @Test
    func redactsQuotedJSONValuesContainingSpaces() {
        let input = #"{"password": "hunter2 with spaces", "token":"abc123def456"}"#
        assertNoSecret(input, ["hunter2 with spaces", "with spaces", "abc123def456"])
    }

    /// 紧凑 JSON（冒号后无空格）与中文冒号都要覆盖。
    @Test
    func redactsCompactJSONAndCJKColon() {
        assertNoSecret(#"{"secret":"s3cr3t-value"}"#, ["s3cr3t-value"])
        assertNoSecret("token：abcdef123456", ["abcdef123456"])
        assertNoSecret("password = p@ssw0rd-with-dashes", ["p@ssw0rd-with-dashes"])
    }

    /// JSON 值里的转义引号不能把脱敏截断在半路。
    @Test
    func redactsJSONValuesWithEscapedQuotes() {
        let input = #"{"token":"ab\"cd ef"}"#
        assertNoSecret(input, ["ab\\\"cd ef", "cd ef"])
    }

    // MARK: - 多行 PEM 私钥

    /// PEM 块里没有 `key: value`，键值对与 base64 规则都盖不住它 ——
    /// 私钥正文是纯字母数字且被换行切开，只能按 BEGIN/END 成对整块吃掉。
    @Test
    func redactsMultilinePEMPrivateKeyBlock() {
        let body1 = "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQ"
        let body2 = "C7x9kQ2mNp5vR8tY1uI3oP6aS4dF7gH0jK2lZ9xC5bV8nM"
        let input = """
        正在加载签名身份
        -----BEGIN PRIVATE KEY-----
        \(body1)
        \(body2)
        -----END PRIVATE KEY-----
        完成
        """
        assertNoSecret(input, [body1, body2])
        let output = LogPrivacyRedactor.redact(input)
        #expect(output.contains("[redacted-private-key]"))
    }

    /// RSA 私钥的 BEGIN 头带 "RSA"，不能只认 "PRIVATE KEY" 这一种写法。
    @Test
    func redactsRSAAndECPrivateKeyHeaders() {
        let body = "MIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGBAK"
        assertNoSecret("-----BEGIN RSA PRIVATE KEY-----\n\(body)\n-----END RSA PRIVATE KEY-----", [body])
        assertNoSecret("-----BEGIN EC PRIVATE KEY-----\n\(body)\n-----END EC PRIVATE KEY-----", [body])
    }

    // MARK: - header 里的 scheme + 凭据

    /// 键值对规则在 `authorization` 后面只看到一个 `Bearer` 词，把 `Bearer` 换掉就收工，
    /// 真正的 token 原样留在日志里。token 是随机串（非 hex、无 `+/`），别的规则也盖不住。
    @Test
    func redactsBearerTokenBehindAuthorizationHeader() {
        let token = "sk_live_51H8xQ2eZvKYlo2C"
        assertNoSecret("Authorization: Bearer \(token)", [token])
        assertNoSecret("authorization: bearer \(token)", [token])
        assertNoSecret("X-Request-Header: Basic \(token)", [token])
    }

    // MARK: - XML plist（既有能力的回归保护）

    @Test
    func redactsXMLPlistSensitiveKeys() {
        let input = """
        <key>UDID</key><string>00008120-000A1B2C3D4E5F6G</string>
        <key>Password</key><string>hunter2</string>
        """
        assertNoSecret(input, ["hunter2"])
    }

    // MARK: - 不得过度脱敏

    /// 脱敏过度会直接毁掉可诊断性 —— 顺利流程的普通日志行必须原样保留。
    @Test
    func keepsOrdinaryDiagnosticTextIntact() {
        let line = "开始签名 微信，阶段 downloading"
        #expect(LogPrivacyRedactor.redact(line) == line)
    }

    /// 多行 PEM 之外的普通分隔线不能被当成私钥块吃掉。
    @Test
    func doesNotSwallowOrdinaryDashes() {
        let line = "---------- 分隔 ----------"
        #expect(LogPrivacyRedactor.redact(line) == line)
    }

    // MARK: - 不得过度脱敏：ISO 时间戳（2026-09-17 从真机日志发现）

    /// 手机号模式 `[0-9][0-9 \-()]{5,}[0-9]` 会把 `2026-09` 整段当成号码，
    /// 于是**日志里所有 ISO 时间戳的年月都没了**（`2026-09-17T06:38:18Z`
    /// → `20****09-17T06:38:18Z`）。日志是唯一的排障通道，时间戳被毁代价很大。
    @Test
    func keepsISOTimestampsIntact() {
        let stamp = "生效=2026-09-17T06:38:18Z"
        #expect(LogPrivacyRedactor.redact(stamp) == stamp)

        let expiry = "主描述文件到期 2026-09-24T06:53:50Z"
        #expect(LogPrivacyRedactor.redact(expiry) == expiry)

        let stamped = "2026-09-17 14:54:02  信息  安装  开始安装"
        #expect(LogPrivacyRedactor.redact(stamped) == stamped)
    }

    /// **这条是原始动机**：证书的 `notBefore` / `notAfter` 相差整整一年，
    /// 脱敏后几乎一模一样（只差 1 秒），看上去像「到期早于生效」——
    /// 排查时差点被当成 bug 报上去。
    @Test
    func certificateValidityPeriodStaysReadable() {
        let notBefore = "生效=2026-09-17T06:38:18Z"
        let notAfter = "到期=2027-09-17T06:38:17Z"
        #expect(LogPrivacyRedactor.redact(notBefore) == notBefore)
        #expect(LogPrivacyRedactor.redact(notAfter) == notAfter)
    }

    /// 光有「不匹配日期中间」还不够：`2026-09-17 14:54:02` 里的 `2026-09-17 14`
    /// 也能被那个字符类吞掉。所以形状判据要独立成立。
    @Test
    func keepsBareDatesFollowedByTimeIntact() {
        let line = "上次续签 2026-09-17 14:54:02 成功"
        #expect(LogPrivacyRedactor.redact(line) == line)
    }

    /// **放宽日期识别不能变成泄露手机号**。真手机号的形态（国家码、区号、8 位固话、
    /// 4-4 分段）都不满足「19xx/20xx + 合法月份」，必须照旧脱敏。
    @Test
    func stillRedactsRealPhoneNumberShapes() {
        assertNoSecret("+86 138 1234 5678", ["13812345678", "1234 5678"])
        assertNoSecret("13812345678", ["13812345678"])
        assertNoSecret("电话 138-1234-5678 结束", ["13812345678"])
        assertNoSecret("固话 020-12345678", ["02012345678"])
        assertNoSecret("分机 1234-5678", ["12345678"])
    }

    /// 反例也要钉住：`1234-56` / `2026-13` / `2026-09-32` 都**不是**合法日期形状，
    /// 不能被当成日期放过去（否则日期识别器就成了绕过脱敏的口子）。
    @Test
    func dateShapeDetectorRejectsPhoneLikeNumbers() {
        assertNoSecret("编号 1234-56", ["123456"])
        assertNoSecret("编号 2026-13", ["202613"])
        assertNoSecret("编号 2026-09-32", ["20260932"])
    }
}
