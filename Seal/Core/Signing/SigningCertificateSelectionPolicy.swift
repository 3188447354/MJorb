import Foundation

enum SigningCertificateSelectionPolicy {
    static let teamMismatchTitle = "开发者团队不匹配"

    static func validateAccountAndTeam(
        for app: AppRecord,
        account: AppleAccountRecord
    ) throws {
        if app.isSeal {
            // Seal 续签的硬性前提：新 Seal 的签名身份（Team + Bundle ID）必须与当前运行包一致，
            // 否则装上的是「另一个身份的应用」——iOS 判为新 App，容器/钥匙串访问组全部失效，
            // 且爱思/其他工具签的 Seal 用自己 Apple ID 续签必然变砖（2026-09-15 真机确认）。
            //
            // 读不到 Team（爱思企业签/通配描述文件常常取不到 teamIdentifier）绝不能放行：
            // 读不到 = 无法确认身份一致 = 续签注定变砖，必须拦下并引导用户用原方式重装。
            guard let teamID = normalized(app.signingTeamID) else {
                throw ImportFailure(
                    title: "无法用当前账号续签 Seal",
                    reason: "这份 Seal 不是用当前 Apple ID 签的（读不到它的开发者团队信息，可能是爱思助手或其他工具签的）。用别的账号续签会改变签名身份，装上后打不开。",
                    recovery: "想用当前 Apple ID 长期使用 Seal：请先在 Seal 里用当前账号完整签名并安装一次 Seal（而不是续签），之后就能正常续签了",
                    code: "SEAL-SELF-104"
                )
            }
            guard teamID.caseInsensitiveCompare(account.teamID) == .orderedSame else {
                throw ImportFailure(
                    title: teamMismatchTitle,
                    reason: "当前 Seal 属于其他开发者团队，所选 Apple ID 无权续签。强行续签会改变签名身份，装上后打不开。",
                    recovery: "使用签名 Seal 时的原 Apple ID 续签；或先用当前账号完整签名并安装一次 Seal",
                    code: "SEAL-SELF-103"
                )
            }
            return
        }
        guard app.state == .installed || app.isSeal else { return }
        guard let boundAccountID = app.accountID else {
            throw ImportFailure(
                title: "缺少签名账号记录",
                reason: "这个应用没有记录上次签名使用的 Apple ID，无法自动续签。",
                recovery: "重新导入 IPA 并签名安装；Seal 自身请在「我的」中添加对应 Apple ID",
                code: "SEAL-AUTH-110"
            )
        }
        guard boundAccountID == account.id else {
            throw ImportFailure(
                title: "Apple ID 不匹配",
                reason: "这个应用是用其他 Apple ID 签名的，续签必须使用原账号。",
                recovery: "在「我的」中切换到原 Apple ID，或用当前账号重新签名安装",
                code: "SEAL-AUTH-111"
            )
        }
        guard let teamID = normalized(app.signingTeamID) else {
            throw ImportFailure(
                title: "缺少团队记录",
                reason: "这个应用没有记录上次签名使用的开发者团队，无法自动续签。",
                recovery: "重新导入 IPA 并签名安装；Seal 自身请在「我的」中添加对应 Apple ID",
                code: "SEAL-AUTH-113"
            )
        }
        guard teamID.caseInsensitiveCompare(account.teamID) == .orderedSame else {
            throw ImportFailure(
                title: teamMismatchTitle,
                reason: "这个应用属于其他开发者团队，当前 Apple ID 无权续签。",
                recovery: "使用原开发者团队的 Apple ID 续签，或用当前账号重新签名安装",
                code: "SEAL-AUTH-112"
            )
        }
    }

    static func resolvedSerialNumber(
        for app: AppRecord,
        account: AppleAccountRecord,
        requestedSerialNumber: String? = nil
    ) throws -> String? {
        try validateAccountAndTeam(for: app, account: account)
        let local = normalized(account.certificateSerialNumber)
        if let requested = normalized(requestedSerialNumber),
           let local,
           requested.caseInsensitiveCompare(local) == .orderedSame {
            return local
        }
        if let selected = normalized(account.selectedCertificateSerialNumber),
           let local,
           selected.caseInsensitiveCompare(local) == .orderedSame {
            return local
        }
        return local
    }

    static func localAvailabilityMessage(
        for app: AppRecord,
        account: AppleAccountRecord
    ) -> String? {
        do {
            try validateAccountAndTeam(for: app, account: account)
        } catch let failure as ImportFailure {
            return failure.reason
        } catch {
            return "续签账号不可用"
        }
        guard let selected = normalized(account.selectedCertificateSerialNumber) else { return nil }
        guard let local = normalized(account.certificateSerialNumber),
              selected.caseInsensitiveCompare(local) == .orderedSame else {
            return "本机没有所选证书对应的私钥，将在签名时自动处理证书。"
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// 证书序列号跨来源比对前的统一归一化：只留十六进制、转大写、剥离前导 0。
    ///
    /// 根因：AltSign（`ALTCertificate.serialNumber`）走 big-number 十六进制，会剥掉最高半字节的
    /// 前导 0；而 `ProvisioningProfileReader` 走 `SecCertificateCopySerialNumberData`，按原始 DER
    /// 字节 `%02X` 拼串，会保留最高半字节的 0（如 `0E76A893…` vs `E76A893…`）。两者实为同一证书、
    /// 同一序列号，直接 `caseInsensitiveCompare` 会误判成“证书已被轮换/不在授权列表”。
    static func normalizedSerialNumber(_ serial: String) -> String {
        let hex = serial.filter(\.isHexDigit).uppercased()
        let trimmed = hex.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }
}
