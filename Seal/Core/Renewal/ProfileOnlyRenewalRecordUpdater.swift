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
                title: "本次续签未完成",
                reason: "续签时缺少主应用的描述文件。",
                recovery: "重新续签",
                code: "SEAL-PROFILE-340",
                condition: .provisioningProfileIncomplete,
                action: .retry,
                retryDisposition: .manual,
                operation: .renew,
                origin: .provisioning
            )
        }
        let installedTargets = [mainBundleIdentifier] + app.extensions.compactMap(\.mappedBundleIdentifier)
        guard Set(installedTargets).count == installedTargets.count,
              Set(installedTargets) == Set(resolvedBindings.keys) else {
            throw ImportFailure(
                title: "本次续签未完成",
                reason: "续签时缺少该应用或其扩展的描述文件。",
                recovery: "重新续签",
                code: "SEAL-PROFILE-341",
                condition: .provisioningProfileIncomplete,
                action: .retry,
                retryDisposition: .manual,
                operation: .renew,
                origin: .provisioning
            )
        }

        // 两阶段提交：先写 pending 草稿，调用方在设备端逐份读回确认后转正。
        // 身份/输入类字段（signingTeamID、signedDeviceIdentifier）直接写顶层，不用拆。
        app.signingTeamID = teamID
        app.signedDeviceIdentifier = deviceIdentifier
        app.lastSignedAt = Date()
        app.entitlementValidationStatus = "已按 Apple App ID 与新描述文件校验"
        app.capabilityValidationStatus = "已按 Apple App ID 与新描述文件校验"
        // ⚠️ 记录键必须是**实际目标** Bundle ID（守卫 R65⑩）：共享模式下 9 个目标共用主描述文件，
        // 若沿用 `SigningTargetRecord(binding:)`（它拿 **profile 内**的 bundleIdentifier 当键），
        // 9 条记录会**全部塌成主 App 一条** ⇒ 缓存与安装前校验逐项匹配失配 ✗。
        // ⇒ 显式传 `signedBundleIdentifier`，profile 元数据仍取自共享的那一份。
        let newSigningTargets = resolvedBindings
            .map { SigningTargetRecord(binding: $0.value, signedBundleIdentifier: $0.key) }
            .sorted { $0.bundleIdentifier < $1.bundleIdentifier }
        var extensionSnapshots: [PendingSignedSnapshot.PendingExtensionSnapshot] = []
        for ext in app.extensions {
            guard let bundleIdentifier = ext.mappedBundleIdentifier,
                  let binding = resolvedBindings[bundleIdentifier] else {
                throw ImportFailure(
                    title: "本次续签未完成",
                    reason: "续签时缺少扩展的描述文件。",
                    recovery: "重新续签",
                    code: "SEAL-PROFILE-342",
                    condition: .provisioningProfileIncomplete,
                    action: .retry,
                    retryDisposition: .manual,
                    operation: .renew,
                    origin: .provisioning
                )
            }
            extensionSnapshots.append(
                PendingSignedSnapshot.PendingExtensionSnapshot(
                    bundleIdentifier: bundleIdentifier,
                    provisioningProfileUUID: binding.profileUUID,
                    provisioningProfileName: binding.profileName,
                    provisioningProfileExpirationDate: binding.expirationDate,
                    certificateSerialNumber: certificateSerialNumber
                )
            )
        }
        app.pendingSignedSnapshot = PendingSignedSnapshot(
            expiryDate: mainBinding.expirationDate,
            provisioningProfileUUID: mainBinding.profileUUID,
            provisioningProfileName: mainBinding.profileName,
            provisioningProfileCreationDate: mainBinding.creationDate,
            provisioningProfileExpirationDate: mainBinding.expirationDate,
            certificateSerialNumber: certificateSerialNumber,
            signingTargets: newSigningTargets,
            extensionSnapshots: extensionSnapshots
        )
    }
}
