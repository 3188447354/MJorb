import Foundation

/// Decides whether an installed third-party app has enough persisted identity to
/// attempt a profile-only refresh. The coordinator adds current-account and
/// current-device checks before it can enter the device transaction.
enum ProfileOnlyRenewalPolicy {
    enum Decision: Equatable, Sendable {
        case eligible(targetBundleIdentifiers: [String])
        case requiresFullResign(FullResignReason)
    }

    enum FullResignReason: Equatable, Sendable {
        case sealSelfReplacement
        case missingInstalledArtifact
        case incompleteSigningIdentity
        case missingTargetRecord
        /// 共享主描述文件的 App 含扩展时**结构上**无法走 profile-only：见 `evaluate` 末尾的说明。
        case sharedMainProfileHasNoExtensionAppIDs
    }

    enum PortalAppIDDecision: Equatable, Sendable {
        case reuse
        case requiresFullResign
    }

    /// Profile-only may reuse the exact portal App ID, but may never create one.
    /// Creating it would consume a free-account App ID slot while presenting the
    /// operation as a no-install renewal.
    static func portalAppIDDecision(isPresent: Bool) -> PortalAppIDDecision {
        isPresent ? .reuse : .requiresFullResign
    }

    static func evaluate(app: AppRecord) -> Decision {
        guard app.isSeal == false else {
            return .requiresFullResign(.sealSelfReplacement)
        }

        guard app.state == .installed,
              app.signedArtifactStatus == .installed,
              app.hasSignedArtifact else {
            return .requiresFullResign(.missingInstalledArtifact)
        }

        guard app.accountID != nil,
              let teamIdentifier = nonBlank(app.signingTeamID),
              let certificateSerialNumber = normalizedSerialNumber(app.certificateSerialNumber),
              let deviceIdentifier = nonBlank(app.signedDeviceIdentifier),
              let mainBundleIdentifier = nonBlank(app.mappedBundleIdentifier),
              let mainProfileUUID = nonBlank(app.provisioningProfileUUID) else {
            return .requiresFullResign(.incompleteSigningIdentity)
        }

        let targetBundleIdentifiers = [mainBundleIdentifier] + app.extensions.compactMap {
            nonBlank($0.mappedBundleIdentifier)
        }
        guard targetBundleIdentifiers.count == app.extensions.count + 1,
              Set(targetBundleIdentifiers).count == targetBundleIdentifiers.count,
              app.signingTargets.count == targetBundleIdentifiers.count else {
            return .requiresFullResign(.missingTargetRecord)
        }

        let signingTargetBundleIdentifiers = app.signingTargets.map(\.bundleIdentifier)
        guard Set(signingTargetBundleIdentifiers).count == signingTargetBundleIdentifiers.count else {
            return .requiresFullResign(.missingTargetRecord)
        }
        let targetsByBundleIdentifier = Dictionary(
            uniqueKeysWithValues: app.signingTargets.map { ($0.bundleIdentifier, $0) }
        )
        guard targetsByBundleIdentifier[mainBundleIdentifier]?.profileUUID?
            .caseInsensitiveCompare(mainProfileUUID) == .orderedSame else {
            return .requiresFullResign(.missingTargetRecord)
        }

        for bundleIdentifier in targetBundleIdentifiers {
            guard let target = targetsByBundleIdentifier[bundleIdentifier],
                  nonBlank(target.profileUUID) != nil,
                  target.teamIdentifier == teamIdentifier,
                  target.deviceIdentifiers.contains(deviceIdentifier),
                  target.certificateSerialNumbers.contains(where: {
                      normalizedSerialNumber($0) == certificateSerialNumber
                  }) else {
                return .requiresFullResign(.missingTargetRecord)
            }
        }

        // 共享主描述文件只为**主 App** 注册门户 App ID（这正是它省配额的方式）⇒ 扩展的 App ID
        // 在 Apple 门户里**从未存在**；而 profile-only 只复用已存在的 App ID、绝不新建
        // （见 `portalAppIDDecision`）⇒ 含扩展的共享模式 App 走 profile-only **必然**在门户阶段
        // 报 `SEAL-PROFILE-337`。真机实证（构建 27）：抖音 9 个 bundle、8 个扩展 App ID 全部查不到，
        // 批量续签「成功 2、失败 1」里失败的那 1 就是它。
        // ⇒ 这类 App 只能走完整重签；完整重签用的仍是共享策略，只需主 App 名额，能成功。
        // 放在**最后**：上面的记录类判据更具体、提示更可操作，应优先报给用户。
        let sharesMainProfile = app.effectiveExtensionProfileStrategy == .sharedMainProfile
        guard app.extensions.isEmpty || sharesMainProfile == false else {
            return .requiresFullResign(.sharedMainProfileHasNoExtensionAppIDs)
        }

        return .eligible(targetBundleIdentifiers: targetBundleIdentifiers)
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedSerialNumber(_ serialNumber: String?) -> String? {
        guard let serialNumber = nonBlank(serialNumber) else { return nil }
        let normalized = serialNumber.uppercased().drop(while: { $0 == "0" })
        return normalized.isEmpty ? "0" : String(normalized)
    }
}
