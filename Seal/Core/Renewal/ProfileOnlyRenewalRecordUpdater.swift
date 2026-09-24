import Foundation

enum ProfileOnlyRenewalRecordUpdater {
    /// - Parameter resolvedBindings: **键是「实际目标」Bundle ID**，值是**该目标依赖的那一份**描述文件。
    ///   共享主描述文件时多个目标会指向同一个值 —— 这是对的（它们真的共用一份），
    ///   调用方必须先用 `ProfileOnlyPortalResult.resolvedBindings(forBundleIdentifiers:)` 解析，
    ///   不要把门户返回的「按描述文件自身 Bundle ID 建的字典」直接传进来 ✗。
    static func apply(
        resolvedBindings: [String: ProvisioningProfileBinding],
        teamID: String,
        certificateSerialNumber: String,
        deviceIdentifier: String,
        to app: inout AppRecord
    ) throws {
        guard let mainBundleIdentifier = app.mappedBundleIdentifier,
              let mainBinding = resolvedBindings[mainBundleIdentifier] else {
            throw ImportFailure(
                title: "描述文件不完整",
                reason: "profile-only 续签缺少主应用的已核验描述文件。",
                recovery: "执行完整重签以重新建立应用身份",
                code: "SEAL-PROFILE-340"
            )
        }
        let installedTargets = [mainBundleIdentifier] + app.extensions.compactMap(\.mappedBundleIdentifier)
        guard Set(installedTargets).count == installedTargets.count,
              Set(installedTargets) == Set(resolvedBindings.keys) else {
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
        // ⚠️ 记录键必须是**实际目标** Bundle ID（守卫 R65⑩）：共享模式下 9 个目标共用主描述文件，
        // 若沿用 `SigningTargetRecord(binding:)`（它拿 **profile 内**的 bundleIdentifier 当键），
        // 9 条记录会**全部塌成主 App 一条** ⇒ 缓存与安装前校验逐项匹配失配 ✗。
        // ⇒ 显式传 `signedBundleIdentifier`，profile 元数据仍取自共享的那一份。
        app.signingTargets = resolvedBindings
            .map { SigningTargetRecord(binding: $0.value, signedBundleIdentifier: $0.key) }
            .sorted { $0.bundleIdentifier < $1.bundleIdentifier }
        for index in app.extensions.indices {
            guard let bundleIdentifier = app.extensions[index].mappedBundleIdentifier,
                  let binding = resolvedBindings[bundleIdentifier] else {
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
