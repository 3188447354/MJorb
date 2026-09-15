import CryptoKit
import Foundation
import Security

/// 真实 DER X.509 自签名证书 fixture，供签名身份读取测试使用。
///
/// 生产端 `ProvisioningProfileReader` 通过 `SecCertificateCreateWithData` 解析
/// `DeveloperCertificates` 中的 `<data>`，因此 fixture 必须提供真实 DER 证书，
/// 不能用序列号的 UTF-8 字节伪造。serialNumber 与 SHA-256 fingerprint 由 DER
/// 动态读取/计算，与生产端解析方式保持一致。
enum TestDeveloperCertificate {
    static let certificateADER: Data = Data(base64Encoded: """
        MIICwDCCAaigAwIBAgIEEjSrzTANBgkqhkiG9w0BAQsFADAiMSAwHgYDVQQDDBdTZWFsIFRlc3QgQ2VydGlmaWNhdGUgQTAeFw0yNjA5MTQxODExMTFaFw0zNjA5MTIxODExMTFaMCIxIDAeBgNVBAMMF1NlYWwgVGVzdCBDZXJ0aWZpY2F0ZSBBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA1akwx7zhTeZcKl+L5Lk52eJ/5jrAEnXzMq8QC4nsEFg1yPgX5xsoQqQBUxY8nGW/1NyxG/HiFfy8FxugVZPJ+KVUUQWMkxtQJDWxAslytIEX0fRFPw/2d5urTkg4SmbPOD6URfggW9QApFqLmWZSx19wHct3GKV7wHdHeHAwwqtrfAUfcM4FmYbSZrkD49L+xgpNk3fpueF7+F5LEgHzsSNDzM+eoKpfE71mx829CipR0ulxoGB2e6utQEUCOCDFLdbtg8NFy0eL344hPW4LsTdpiDGoanWrlZXiwQ0Vx1jjD/W5nKG4LL/gcPo3hi9VQugo+/9POoAS37c1FI9gzwIDAQABMA0GCSqGSIb3DQEBCwUAA4IBAQCsd3hWFgWNfOwnDQU5ISTsrbttH72XLlvJ3gfmQ48T7LfOT0a2Lr93DQx2+F0ElD3pMFu0Fo+Pc66qwatdxvFgfAQ4UN5gGbvE6qQZmMlTJMW+giKDwerRbBnOQHQGNB776GyxojZ3489I9UL5EG4R5Om7S99BHmQ9GPt/Tc6uBAUCzAcHGlUIlC95bAPf84C1orKun2dQ2Jz1scaPFiYnB5kxdGjbXOJk3FSdajPTjmgXxoJYpriR83NqJheaEhuCbnEATqPAvJzuJMguoI/7elhHFyQnBdG4yRdHrG35ZW0mD/yiUWZHJ4QrXQhfhB5kDOLjKxoaTYivsgwkQv63
        """)!

    static let certificateBDER: Data = Data(base64Encoded: """
        MIICvzCCAaegAwIBAgIDW34qMA0GCSqGSIb3DQEBCwUAMCIxIDAeBgNVBAMMF1NlYWwgVGVzdCBDZXJ0aWZpY2F0ZSBCMB4XDTI2MDkxNDE4MTExMVoXDTM2MDkxMjE4MTExMVowIjEgMB4GA1UEAwwXU2VhbCBUZXN0IENlcnRpZmljYXRlIEIwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCLYgbwx4WnM7t/DxqpqcHh1qwKkV4JLSVwtJjkaojZBY/Mmlw+xCgtTnHPHdRKRxOE33Tjh3zfpgW02Ngz0bFGvT1Q5olJl7oeNtYwnLuUd/YYfK3AvQxb2TPaFX3V3zVvYlY3Uaht/ZVGAkkNyNbR6yCOEwtlNuRh4GL94qytRqMfiSsh6XnslfA/bVkfiDc8zcM08gesvEZzxDBfXHyA+M+U1fHlP2rOvL6xVJePrTEfQodyqtSL8im2O0PuoXWCN3/LVlVyF6FXCzmhRuusFhKfvH2WuWdhpFyYUrdnSms0scsHMo4xIuRDCOeP/Hjs5/aLA1bGO6GtliCTOHz3AgMBAAEwDQYJKoZIhvcNAQELBQADggEBABT01bD0pXXWqHaEPXVGKaNY6kxPSJrIsSxYvj6TTp6yyuCtJ5DIEnv/VOMD2gLX5KtdTpSVcb/xtEPPrfFrTIajlSlC+wzBKuWxVY8amQ4rD42rueWPVkjOj+rIzsG2oxBoz/Kre6QZOGOtNebQ7mdoN649VtD0utEiH5cH9aIVxkCeNmJAEm4/2V9KQaWOztoGY69XEq5XTZoYoLCMXXox8RlU553lYzevLWbUU5Ddz7nyiY6lDOrwIcpuwwK02Wz40KydXMDCS5FL18XZqUBgGH/o4hyVts/pfLAMha9grWXxS7SJ11cDihJjECue5eIf299ixJZntkjxB1D5wJQ=
        """)!

    /// 与 `ProvisioningProfileReader` 相同的序列号读取方式：
    /// `SecCertificateCopySerialNumberData` 原始字节按 `%02X` 拼串。
    static func serialNumberHex(der: Data) -> String {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let serialData = SecCertificateCopySerialNumberData(certificate, nil) else {
            return ""
        }
        return (serialData as Data).map { String(format: "%02X", $0) }.joined()
    }

    static func sha256Fingerprint(der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }
}