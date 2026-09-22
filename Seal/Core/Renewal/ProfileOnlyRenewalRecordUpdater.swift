import Foundation

enum ProfileOnlyRenewalRecordUpdater {
    static func apply(
        bindings: [String: ProvisioningProfileBinding],
        teamID: String,
        certificateSerialNumber: String,
        deviceIdentifier: String,
        to app: inout AppRecord
    ) throws {
        guard let mainBundleIdentifier = app.mappedBundleIdentifier,
              let mainBinding = bindings[mainBundleIdentifier] else {
            throw ImportFailure(
                title: "描述文件不完整",
                reason: "profile-only 续签缺少主应用的已核验描述文件。",
                recovery: "执行完整重签以重新建立应用身份",
                code: "SEAL-PROFILE-340"
            )
        }
        let installedTargets = [mainBundleIdentifier] + app.extensions.compactMap(\.mappedBundleIdentifier)
        guard Set(installedTargets).count == installedTargets.count,
              Set(installedTargets) == Set(bindings.keys) else {
            throw ImportFailure(
                title: "描述文件不完整",
                reason: "profile-only 续签没有覆盖当前应用的全部已安装目标。",
                recovery: "执行完整重签以重新建立应用身份",
                code: "SEAL-PROFILE-341"
            )
        }

        app.signingTeamID = teamID
        app.certificateSerialNumber = certificateSerialNumber
        app.signedDeviceIdentifier = deviceIdentifier
        app.provisioningProfileUUID = mainBinding.profileUUID
        app.provisioningProfileName = mainBinding.profileName
        app.provisioningProfileCreationDate = mainBinding.creationDate
        app.provisioningProfileExpirationDate = mainBinding.expirationDate
        app.expiryDate = mainBinding.expirationDate
        app.lastSignedAt = Date()
        app.entitlementValidationStatus = "已按 Apple App ID 与新描述文件校验"
        app.capabilityValidationStatus = "已按 Apple App ID 与新描述文件校验"
        app.signingTargets = bindings.values
            .map(SigningTargetRecord.init(binding:))
            .sorted { $0.bundleIdentifier < $1.bundleIdentifier }
        for index in app.extensions.indices {
            guard let bundleIdentifier = app.extensions[index].mappedBundleIdentifier,
                  let binding = bindings[bundleIdentifier] else {
                throw ImportFailure(
                    title: "描述文件不完整",
                    reason: "profile-only 续签缺少扩展的已核验描述文件。",
                    recovery: "执行完整重签以重新建立应用身份",
                    code: "SEAL-PROFILE-342"
                )
            }
            app.extensions[index].provisioningProfileUUID = binding.profileUUID
            app.extensions[index].provisioningProfileName = binding.profileName
            app.extensions[index].provisioningProfileExpirationDate = binding.expirationDate
            app.extensions[index].certificateSerialNumber = certificateSerialNumber
        }
    }
}
