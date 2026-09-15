import Foundation

struct AccountSecret: Codable, Equatable, Sendable {
    let email: String
    let accountIdentifier: String
    let dsid: String
    let authToken: String
    /// Apple ID 密码，用于 authToken 失效（1100）时自动重新登录
    /// 保存在钥匙串加密的 AccountSecret 中，参照 SideStore 官方做法
    let password: String?

    /// 向后兼容字段：当前选中的签名身份。
    /// 新版本同时把每一张曾经自动创建过的证书的 P12 按 Serial 保存在
    /// `certificateP12BySerial`，避免创建新证书时覆盖旧证书私钥，导致仍在设备上使用
    /// 旧证书的 App 无法续签（本次真机反馈暴露的根因）。
    var certificateP12: Data?
    var certificateSerialNumber: String?
    var certificateMachineIdentifier: String?

    /// 证书是账号级的，但一台设备上可能还保留多个证书对应的私钥。
    /// key 使用归一化后的证书序列号；旧账号没有这个字段时自动解码为空。
    var certificateP12BySerial: [String: Data]
    var certificateMachineIdentifierBySerial: [String: String]

    init(
        email: String,
        accountIdentifier: String,
        dsid: String,
        authToken: String,
        password: String?,
        certificateP12: Data? = nil,
        certificateSerialNumber: String? = nil,
        certificateMachineIdentifier: String? = nil,
        certificateP12BySerial: [String: Data] = [:],
        certificateMachineIdentifierBySerial: [String: String] = [:]
    ) {
        self.email = email
        self.accountIdentifier = accountIdentifier
        self.dsid = dsid
        self.authToken = authToken
        self.password = password
        self.certificateP12 = certificateP12
        self.certificateSerialNumber = certificateSerialNumber
        self.certificateMachineIdentifier = certificateMachineIdentifier
        self.certificateP12BySerial = certificateP12BySerial
        self.certificateMachineIdentifierBySerial = certificateMachineIdentifierBySerial
    }

    /// Codable 迁移：旧 Keychain JSON 没有两个 map 时按空字典处理。
    enum CodingKeys: String, CodingKey {
        case email, accountIdentifier, dsid, authToken, password
        case certificateP12, certificateSerialNumber, certificateMachineIdentifier
        case certificateP12BySerial, certificateMachineIdentifierBySerial
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = try container.decode(String.self, forKey: .email)
        accountIdentifier = try container.decode(String.self, forKey: .accountIdentifier)
        dsid = try container.decode(String.self, forKey: .dsid)
        authToken = try container.decode(String.self, forKey: .authToken)
        password = try container.decodeIfPresent(String.self, forKey: .password)
        certificateP12 = try container.decodeIfPresent(Data.self, forKey: .certificateP12)
        certificateSerialNumber = try container.decodeIfPresent(String.self, forKey: .certificateSerialNumber)
        certificateMachineIdentifier = try container.decodeIfPresent(String.self, forKey: .certificateMachineIdentifier)
        certificateP12BySerial = try container.decodeIfPresent(
            [String: Data].self,
            forKey: .certificateP12BySerial
        ) ?? [:]
        certificateMachineIdentifierBySerial = try container.decodeIfPresent(
            [String: String].self,
            forKey: .certificateMachineIdentifierBySerial
        ) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(email, forKey: .email)
        try container.encode(accountIdentifier, forKey: .accountIdentifier)
        try container.encode(dsid, forKey: .dsid)
        try container.encode(authToken, forKey: .authToken)
        try container.encodeIfPresent(password, forKey: .password)
        try container.encodeIfPresent(certificateP12, forKey: .certificateP12)
        try container.encodeIfPresent(certificateSerialNumber, forKey: .certificateSerialNumber)
        try container.encodeIfPresent(certificateMachineIdentifier, forKey: .certificateMachineIdentifier)
        try container.encode(certificateP12BySerial, forKey: .certificateP12BySerial)
        try container.encode(certificateMachineIdentifierBySerial, forKey: .certificateMachineIdentifierBySerial)
    }

    /// 重新认证只替换登录凭据，完整保留当前及历史签名材料。
    func preservingSigningMaterial(from previous: AccountSecret?) -> AccountSecret {
        guard let previous, previous.accountIdentifier == accountIdentifier else { return self }
        var copy = self
        copy.certificateP12 = previous.certificateP12
        copy.certificateSerialNumber = previous.certificateSerialNumber
        copy.certificateMachineIdentifier = previous.certificateMachineIdentifier
        copy.certificateP12BySerial = previous.certificateP12BySerial
        copy.certificateMachineIdentifierBySerial = previous.certificateMachineIdentifierBySerial
        return copy
    }

    /// 用新的 authToken 和 dsid 创建副本（自动重登时使用）。
    func withNewSession(dsid: String, authToken: String) -> AccountSecret {
        AccountSecret(
            email: email,
            accountIdentifier: accountIdentifier,
            dsid: dsid,
            authToken: authToken,
            password: password,
            certificateP12: certificateP12,
            certificateSerialNumber: certificateSerialNumber,
            certificateMachineIdentifier: certificateMachineIdentifier,
            certificateP12BySerial: certificateP12BySerial,
            certificateMachineIdentifierBySerial: certificateMachineIdentifierBySerial
        )
    }

    /// 取指定证书的 P12。旧账号只有 current 字段时也能读取。
    func p12(for serialNumber: String) -> Data? {
        let key = Self.normalizedSerial(serialNumber)
        if let data = certificateP12BySerial[key] { return data }
        guard let current = certificateSerialNumber,
              Self.normalizedSerial(current) == key else { return nil }
        return certificateP12
    }

    func machineIdentifier(for serialNumber: String) -> String? {
        let key = Self.normalizedSerial(serialNumber)
        if let stored = certificateMachineIdentifierBySerial[key] { return stored }
        guard let current = certificateSerialNumber,
              Self.normalizedSerial(current) == key else { return nil }
        return certificateMachineIdentifier
    }

    /// 把指定序列号的材料提升为当前签名身份，同时保留其它证书材料。
    func activated(for serialNumber: String, machineIdentifier: String?) -> AccountSecret? {
        guard let p12 = p12(for: serialNumber) else { return nil }
        var copy = self
        copy.certificateP12 = p12
        copy.certificateSerialNumber = serialNumber
        copy.certificateMachineIdentifier = machineIdentifier ?? self.machineIdentifier(for: serialNumber)
        return copy
    }

    /// 保存一张证书的私钥，同时更新 current 兼容字段；不会覆盖其它证书的 P12。
    mutating func storeCertificateMaterial(
        p12: Data,
        serialNumber: String,
        machineIdentifier: String?
    ) {
        // 在覆盖 current 之前先把旧身份归档进 map。这样新证书创建失败、
        // 或旧 App 仍在使用旧证书时，后续同步仍能找到旧 P12 继续签名。
        if let oldSerial = certificateSerialNumber,
           let oldP12 = certificateP12 {
            let oldKey = Self.normalizedSerial(oldSerial)
            certificateP12BySerial[oldKey] = oldP12
            if let oldMachineIdentifier = certificateMachineIdentifier {
                certificateMachineIdentifierBySerial[oldKey] = oldMachineIdentifier
            }
        }

        let key = Self.normalizedSerial(serialNumber)
        certificateP12BySerial[key] = p12
        if let machineIdentifier {
            certificateMachineIdentifierBySerial[key] = machineIdentifier
        }
        certificateP12 = p12
        certificateSerialNumber = serialNumber
        certificateMachineIdentifier = machineIdentifier
    }

    /// 清理所有本机签名材料（撤销当前本机身份时使用）。
    mutating func clearAllCertificateMaterials() {
        certificateP12 = nil
        certificateSerialNumber = nil
        certificateMachineIdentifier = nil
        certificateP12BySerial.removeAll()
        certificateMachineIdentifierBySerial.removeAll()
    }

    /// 撤销证书后删除本机保存的对应 P12 材料（只删指定序列号，不清全量）。
    mutating func removeStoredCertificateMaterial(serialNumber: String) {
        let key = Self.normalizedSerial(serialNumber)
        certificateP12BySerial.removeValue(forKey: key)
        certificateMachineIdentifierBySerial.removeValue(forKey: key)
        if let current = certificateSerialNumber, Self.normalizedSerial(current) == key {
            certificateP12 = nil
            certificateSerialNumber = nil
            certificateMachineIdentifier = nil
        }
    }

    private static func normalizedSerial(_ serial: String) -> String {
        var result = serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        while result.hasPrefix("0") { result.removeFirst() }
        return result
    }
}
