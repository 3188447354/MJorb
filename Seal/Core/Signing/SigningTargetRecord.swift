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
    let entitlementKeys: [String]

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
        entitlementKeys = binding.entitlementKeys
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
        entitlementKeys: [String]
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.profileUUID = profileUUID
        self.profileName = profileName
        self.profileCreationDate = profileCreationDate
        self.profileExpirationDate = profileExpirationDate
        self.teamIdentifier = teamIdentifier
        self.certificateSerialNumbers = certificateSerialNumbers
        self.deviceIdentifiers = deviceIdentifiers
        self.entitlementKeys = entitlementKeys
    }
}
