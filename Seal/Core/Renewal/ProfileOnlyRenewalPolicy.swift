import Foundation

/// 运行产物的**实时签名身份** —— 记录之外的第二条续签准入依据。
///
/// 上游 SideStore 的 `refresh` 管线根本**不看数据库记录**：它的准入是
/// `VerifyCertificateOperation(willResign: false)`，输入是**已安装产物的签名证书** ——
/// 自身从运行中的 Mach-O 读（`CertificateManager.getSigningCertificate(at:)` ＋
/// `Bundle.Info.activeBundleURL`），第三方读安装时缓存的 `<app>/signing_certificate.der`
/// （`CacheSigningCertOperation`）。本仓对**自身**有完全等价的现成物：
/// `SelfAppMetadata.current()` 读运行包的 CMS 签名身份（`AppBundleSigningIdentityReader`）。
///
/// 由 `ProfileOnlyRenewalPolicy.liveIdentity(installedIdentity:app:)` 构造；
/// 只有「运行包能自证身份」时才存在（任何一项读不出来 ⇒ `nil`，**绝不猜**）。
struct LiveProfileOnlyIdentity: Equatable, Sendable {
    /// 运行包主目标的 Bundle ID（从 CMS 身份里读出来的那个）。
    let mainBundleIdentifier: String
    let profileUUID: String
    let certificateSerialNumber: String
    let teamIdentifier: String
    /// 该应用在设备上实际存在的全部签名目标（主 App ＋ 扩展）。
    let targetBundleIdentifiers: [String]
}

/// Decides whether an installed app has enough persisted identity to attempt a
/// profile-only refresh. The coordinator adds current-account and current-device
/// checks before it can enter the device transaction.
///
/// 🔴 **Seal 自己不再被排除**（2026-09-25）：它与任何第三方已装应用走**同一条**判据 ——
/// 「只更新描述文件、不重新安装」对 Seal 同样适用，判定依据是**记录是否完整**，
/// 与「这是谁的应用」无关。理由见 `evaluate(app:)`。
///
/// 🔴 **记录不是唯一入口**（2026-09-26，构建 46 真机）：只认「持久化记录完整」仍然不够。
/// Seal 自身的记录由 `SelfAppRegistrar` 维护，它**从不写** `signedDeviceIdentifier` /
/// `signingTargets` / `signedIPARelativePath`（⇒ `hasSignedArtifact` 恒为 false）
/// ⇒ 上面那条「不按身份排除」在真机上**一次都没生效过**：构建 46 日志里
/// 01:24:30「开始续签：Seal」紧接着就是「续签路径已确认：需要完整重签并安装」，
/// 而且**没有** `SEAL-PROFILE-363` —— 说明它是在更早的准入处就返回了 false。
/// ⇒ 记录不完整但**运行产物身份可读且完整**时一样放行（见 `evaluate(app:liveIdentity:)`）。
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
    /// `OperationStepDefinition.refresh` 是**五步**（2026-09-26 逐行复核
    /// `upstream/SideStore/SideStore/Core/Operations/OperationStepDefinition.swift:82-88`）：
    /// `updateAppCertificate` / `verifyCertificate` / `fetchProvisioningProfiles` /
    /// `cacheResignedMetadata` / `refreshApp`；底层就是 misagent 的
    /// `installProvisioningProfile`（本仓对应 `ProfileOnlyProvisioningProfileInstaller`
    /// → `Minimuxer.installProvisioningProfile`），**对它自己同样如此**；
    /// 自替换（`handleSelfReinstallation`）只出现在 install / update / resign 管线里。
    ///
    /// ⚠️ 这段注释原先写的是「三步」——那是 2026-09-08 之前的形态，
    /// `39a97cd039` 起插入 `cacheResignedMetadata`，`verifyCertificate` 更晚。
    /// **别再照抄旧注释**（本项目「过时注释比没有注释更贵」的老坑）。
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

    /// 从「运行包身份」构造 `LiveProfileOnlyIdentity`。任何一项读不出来都返回 nil —— **绝不猜**。
    ///
    /// - Parameter installedIdentity: `SelfAppMetadata.current()?.installedIdentity`。
    ///   `isComplete == false`（主程序或任一扩展的 CMS 身份读不出来）时整体放弃：
    ///   半份身份不能当准入门票（与 `CertificateCleanupPolicy` 的 `identityConfidence` 同口径）。
    ///
    /// ⚠️ 调用方**必须**只在「这确实是该 app 自己的运行包」时调用 —— `SelfAppMetadata.current()`
    /// 读的是 `Bundle.main`，对第三方 App 用它会读成 **Seal 自己**的身份（假阳性）。
    /// 见 `SigningCoordinator.liveProfileOnlyIdentity(for:)`。
    static func liveIdentity(
        installedIdentity: InstalledIdentity?,
        app: AppRecord
    ) -> LiveProfileOnlyIdentity? {
        guard let installedIdentity,
              installedIdentity.isComplete,
              let mainTarget = installedIdentity.mainTarget,
              let mappedMainBundleIdentifier = nonBlank(app.mappedBundleIdentifier),
              mainTarget.bundleIdentifier.caseInsensitiveCompare(mappedMainBundleIdentifier) == .orderedSame,
              let profileUUID = nonBlank(mainTarget.profileUUID),
              let serialNumber = nonBlank(mainTarget.signerSerialNumber),
              let teamIdentifier = nonBlank(mainTarget.teamIdentifier) else {
            return nil
        }
        let targets = [mappedMainBundleIdentifier] + app.extensions.compactMap {
            nonBlank($0.mappedBundleIdentifier)
        }
        // 目标不能重复：重复会让「每个目标都有描述文件」的后续判据变成假话。
        guard Set(targets).count == targets.count else { return nil }
        return LiveProfileOnlyIdentity(
            mainBundleIdentifier: mappedMainBundleIdentifier,
            profileUUID: profileUUID,
            certificateSerialNumber: serialNumber,
            teamIdentifier: teamIdentifier,
            targetBundleIdentifiers: targets
        )
    }

    /// 记录之外的**第二条准入通道**：以「运行产物的实时身份」为准（对齐上游 `refresh`）。
    ///
    /// 适用场景：记录里缺字段（Seal 自身就是如此），但**运行包能自证身份**。
    /// 此时记录完整性不再必要 —— 运行包本身就是「已安装」这个事实的最强证据，
    /// 比任何 DB 字段都强（DB 字段可能是安装前乐观写入的、也可能是旧值）。
    ///
    /// ⚠️ 两条通道**都不放松**的是「身份必须可核验」：实时身份必须 `isComplete`
    /// （主程序 ＋ 全部扩展的 CMS 都读得出来）、主目标 Bundle ID 必须与记录里的映射 ID
    /// 一致、profile UUID 与签名者序列号都必须非空。
    static func evaluate(
        app: AppRecord,
        liveIdentity: LiveProfileOnlyIdentity?
    ) -> Decision {
        if let liveIdentity,
           let mappedMainBundleIdentifier = nonBlank(app.mappedBundleIdentifier),
           liveIdentity.mainBundleIdentifier.caseInsensitiveCompare(mappedMainBundleIdentifier)
               == .orderedSame {
            return .eligible(targetBundleIdentifiers: liveIdentity.targetBundleIdentifiers)
        }
        return evaluate(app: app)
    }

    /// 准入通过后判定「设备绑定」是否成立。
    ///
    /// 记录通道要求 `signedDeviceIdentifier` 与会话设备一致；**实时身份通道不适用**
    /// —— `LiveProfileOnlyIdentity` 证明的是「运行中的产物就是记录里那个应用」，
    /// 比一条可能过期的 DB 字段更强，而 Seal 自身的记录里**从来没有**这个字段
    /// （`SelfAppRegistrar` 不写它，也不该编造一个）。
    static func isBoundToCurrentDevice(
        app: AppRecord,
        deviceIdentifier: String,
        liveIdentity: LiveProfileOnlyIdentity?
    ) -> Bool {
        if app.signedDeviceIdentifier?.caseInsensitiveCompare(deviceIdentifier) == .orderedSame {
            return true
        }
        return liveIdentity != nil
    }

    /// 准入通过后取「该应用实际被哪张证书签名」。
    /// 记录里的值是安装前写入的，可能是旧证书；实时身份是运行包 CMS 里的真值。
    static func effectiveCertificateSerialNumber(
        app: AppRecord,
        liveIdentity: LiveProfileOnlyIdentity?
    ) -> String? {
        nonBlank(app.certificateSerialNumber) ?? liveIdentity?.certificateSerialNumber
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
