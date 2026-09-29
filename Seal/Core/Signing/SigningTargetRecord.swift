import Foundation

struct SigningTargetRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String { bundleIdentifier }

    let bundleIdentifier: String
    let profileUUID: String?
    let profileName: String?
    let profileCreationDate: Date?
    let profileExpirationDate: Date
    let teamIdentifier: String
    let certificateSerialNumbers: [String]
    let deviceIdentifiers: [String]
    /// 该目标被**实授**的完整 entitlements（键 + 值，`ProvisioningEntitlementValue`）。
    ///
    /// 字段从 `ProvisioningProfileBinding.entitlements` 落盘（首签与 profile-only 续签两条路径都写）。
    /// 这是 profile-only 续签「免解压」的依据：续签侧只换描述文件、从不重签，
    /// 它对权限的唯一需求就是「新描述文件仍授予旧描述文件授予过的那些键」——
    /// 旧描述文件的 entitlements 已在这里，续签时据此重建请求集、对新描述文件逐键对账，
    /// 不再需要解开 IPA 重新读 Mach-O。
    ///
    /// ⚠️ 旧记录（1.3.4x 之前）没有这个字段 ⇒ 解码时落 `[:]`（向后兼容）。
    /// 空字典即「无持久化权限」⇒ 续签侧据此回落"解压 IPA 重建"的旧路径，
    /// 直到下一次完整重签或 profile-only 续签把新值写回。
    let entitlements: [String: ProvisioningEntitlementValue]

    var entitlementKeys: [String] { entitlements.keys.sorted() }

    init(binding: ProvisioningProfileBinding) {
        self.init(
            binding: binding,
            signedBundleIdentifier: binding.bundleIdentifier
        )
    }

    init(
        binding: ProvisioningProfileBinding,
        signedBundleIdentifier: String
    ) {
        // 共享主描述文件时，profile 内的 application-identifier 属于主 App；
        // 记录的 target 则必须保留实际被重签的扩展 Bundle ID，供缓存和安装前校验逐项匹配。
        bundleIdentifier = signedBundleIdentifier
        profileUUID = binding.profileUUID
        profileName = binding.profileName
        profileCreationDate = binding.creationDate
        profileExpirationDate = binding.expirationDate
        teamIdentifier = binding.teamIdentifier
        certificateSerialNumbers = binding.certificateSerialNumbers
        deviceIdentifiers = binding.deviceIdentifiers
        entitlements = binding.entitlements
    }

    init(
        bundleIdentifier: String,
        profileUUID: String?,
        profileName: String?,
        profileCreationDate: Date?,
        profileExpirationDate: Date,
        teamIdentifier: String,
        certificateSerialNumbers: [String],
        deviceIdentifiers: [String],
        entitlements: [String: ProvisioningEntitlementValue] = [:]
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.profileUUID = profileUUID
        self.profileName = profileName
        self.profileCreationDate = profileCreationDate
        self.profileExpirationDate = profileExpirationDate
        self.teamIdentifier = teamIdentifier
        self.certificateSerialNumbers = certificateSerialNumbers
        self.deviceIdentifiers = deviceIdentifiers
        self.entitlements = entitlements
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case profileUUID
        case profileName
        case profileCreationDate
        case profileExpirationDate
        case teamIdentifier
        case certificateSerialNumbers
        case deviceIdentifiers
        case entitlements
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        profileUUID = try container.decodeIfPresent(String.self, forKey: .profileUUID)
        profileName = try container.decodeIfPresent(String.self, forKey: .profileName)
        profileCreationDate = try container.decodeIfPresent(Date.self, forKey: .profileCreationDate)
        profileExpirationDate = try container.decode(Date.self, forKey: .profileExpirationDate)
        teamIdentifier = try container.decode(String.self, forKey: .teamIdentifier)
        certificateSerialNumbers = try container.decode([String].self, forKey: .certificateSerialNumbers)
        deviceIdentifiers = try container.decode([String].self, forKey: .deviceIdentifiers)
        entitlements = try container.decodeIfPresent(
            [String: ProvisioningEntitlementValue].self,
            forKey: .entitlements
        ) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encodeIfPresent(profileUUID, forKey: .profileUUID)
        try container.encodeIfPresent(profileName, forKey: .profileName)
        try container.encodeIfPresent(profileCreationDate, forKey: .profileCreationDate)
        try container.encode(profileExpirationDate, forKey: .profileExpirationDate)
        try container.encode(teamIdentifier, forKey: .teamIdentifier)
        try container.encode(certificateSerialNumbers, forKey: .certificateSerialNumbers)
        try container.encode(deviceIdentifiers, forKey: .deviceIdentifiers)
        try container.encode(entitlements, forKey: .entitlements)
    }
}