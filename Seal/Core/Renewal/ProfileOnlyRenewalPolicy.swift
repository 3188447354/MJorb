import Foundation

/// Decides whether an installed app has enough persisted identity to attempt a
/// profile-only refresh. The coordinator adds current-account and current-device
/// checks before it can enter the device transaction.
///
/// 🔴 **Seal 自己不再被排除**（2026-09-25）：它与任何第三方已装应用走**同一条**判据 ——
/// 「只更新描述文件、不重新安装」对 Seal 同样适用，判定依据是**记录是否完整**，
/// 与「这是谁的应用」无关。理由见 `evaluate(app:)`。
enum ProfileOnlyRenewalPolicy {
    enum Decision: Equatable, Sendable {
        case eligible(targetBundleIdentifiers: [String])
        case requiresFullResign(FullResignReason)
    }

    enum FullResignReason: Equatable, Sendable {
        case missingInstalledArtifact
        case incompleteSigningIdentity
        case missingTargetRecord
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

    /// 判定「这条记录是否完整到足以只换描述文件」。
    ///
    /// 🔴 **Seal 自己不再被排除**（2026-09-25 真机，构建 44）。
    ///
    /// 旧实现的第一句是 `guard app.isSeal == false else { return .requiresFullResign(.sealSelfReplacement) }`
    /// ⇒ Seal **永远**走完整重签 + **自替换安装** ⇒ 进程被系统换掉：
    ///   · 批量续签跑到 Seal 那一项（第 3/3 项）时，队列项还停在 `running` 就随进程消失
    ///     ⇒ 新进程启动后降级成未知，报 `SEAL-RENEW-007`「1 个应用的结果未知，需要重新核验」；
    ///   · 同一轮里 `SEAL-SELF-109`（Seal 自更新安装遇到未预期错误）连报两次，
    ///     并引出多轮自替换结算 + `SEAL-INSTALL-707`；
    ///   · 用户看到的是「续签全部」反复中断、必须手动重试。
    ///
    /// 而「续签」在上游 SideStore 的稳定实现里**从不重签、从不重装** —— 它的
    /// `PipelineStepDefinition.refresh` 只有 `fetchProvisioningProfiles` /
    /// `cacheResignedMetadata` / `refreshApp` 三步，底层就是 misagent 的
    /// `installProvisioningProfile`（本仓对应 `ProfileOnlyProvisioningProfileInstaller`
    /// → `Minimuxer.installProvisioningProfile`），**对它自己同样如此**；
    /// 自替换（`handleSelfReinstallation`）只出现在 install / update / resign 管线里。
    ///
    /// ⚠️ 这里删掉的是「按身份一刀切」，**不是安全边界**：记录不完整（缺已装产物 /
    /// 缺签名身份 / 缺目标记录）时，下面几条判据**一条都没有放松**，照旧回落完整重签。
    static func evaluate(app: AppRecord) -> Decision {
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

        // ⚠️ **这里曾经按「共享主描述文件 + 含扩展 ⇒ 完整重签」一刀切，已撤销**（2026-09-24）。
        // 那条判据能签上，但把快路径整个丢掉了：抖音续签变成 658 MB 完整重签 + 安装（约 4 分钟），
        // 而用户要的是「续签就该是仅更新描述文件」。真正的问题是**续签侧不支持共享策略**，
        // 已在 `prepareProfileOnlyRenewal` 修好（共享模式只取主 App 一份描述文件注入设备，
        // 与设备端本来就只登记这一份相符）⇒ 准入判据不再需要区分策略，交回续签侧按
        // **应用当初实际签名用的策略**分流。
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
