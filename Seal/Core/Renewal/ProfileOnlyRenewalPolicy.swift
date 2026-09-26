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
/// 由 `ProfileOnlyRenewalPolicy.liveIdentity(installedIdentity:runningVersion:app:)` 构造；
/// 只有「运行包能自证身份」时才存在（任何一项读不出来 ⇒ `nil`，**绝不猜**）。
struct LiveProfileOnlyIdentity: Equatable, Sendable {
    /// 运行包主目标的 Bundle ID（从 CMS 身份里读出来的那个）。
    let mainBundleIdentifier: String
    let profileUUID: String
    let certificateSerialNumber: String
    let teamIdentifier: String
    /// 该应用在设备上实际存在的全部签名目标（主 App ＋ 扩展）。
    let targetBundleIdentifiers: [String]
    /// **正在运行的那个包**的 `CFBundleShortVersionString`。
    ///
    /// 🔴 为什么必须有（2026-09-26 用户实测）：记录里的 `version` 描述的是**已导入的源包**，
    /// 不是「设备上正在跑的那个」。覆盖更新（`ImportWorkflow.makeInstalledUpdateRecord`）
    /// 会把它写成新导入包的版本，并把 `hasPendingSelfUpdateSource` 置真 —— 这条记录**刻意**
    /// 保留新版本号，等下一次安装生效（见 `SelfAppRegistrar` 那段注释）。
    /// 而 profile-only 只换描述文件、**从不安装** ⇒ 只看 Bundle ID 相等的准入会把
    /// 「已导入 1.3.20、实际跑着 1.3.19」判成合格 ⇒ 新版本**永远装不上**，
    /// 界面却一直显示 1.3.20（用户实测：「关于」里仍是 1.3.19）。
    let runningVersion: String
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
        /// 🔴 **本机没有「该应用当前使用的那张证书」的私钥**（2026-09-26，构建 48 真机）。
        ///
        /// 记录里的 `certificateSerialNumber` 可以指向一张**只有 Apple 门户上还在、本机
        /// Keychain 里已经没有私钥**的证书。三种成因都真实存在：
        ///   · 首次把 Seal 装到手机上 —— `SelfAppRegistrar` 从**运行包**的描述文件回填序列号，
        ///     而重装 Seal 会清空 Keychain（构建 48 日志：`本机有私钥 0 张`）；
        ///   · 删掉 Apple ID 后重新添加；
        ///   · 证书轮换刚发生 —— 旧证书被撤销、新证书刚建好，而记录还指着旧的那个。
        ///
        /// 此时 `prepareProfileOnlyRenewal` 会在 `existingProfileOnlyCertificate` 处抛
        /// `SEAL-PROFILE-334`，**而准入已经宣布「仅更新描述文件」** ⇒ 用户看到的是
        /// 「说好不重装，结果失败」。构建 48 日志里这一条出现 **4 次**，其中一次是
        /// 批量续签的第 3/3 项（Seal 自己），整批因此被记成「失败 1」。
        ///
        /// ⇒ 把这条判据**提前到准入**：本机证书不可用就回落完整重签。完整重签会申请/复用
        ///   一张**本机有私钥**的证书并把序列号写回记录，下一次准入自然又走 profile-only
        ///   —— 这正是用户要的「匹配之后后续再走不重装的更新续签模式」。
        ///   （同一份日志已证明这条路通：撤销 `…E9DA0CD9` 后新建 `…976EFE08`，
        ///   随后 LiveContainer / Guoguo 的完整重签都复用了它。）
        case missingLocalCertificateMaterial

        /// 🔴 **记录里有一条「已导入但尚未生效」的更新源**（2026-09-26，用户实测）。
        ///
        /// 覆盖更新把记录写成**新导入包**的版本号（`hasPendingSelfUpdateSource = true`，
        /// 见 `ImportWorkflow.makeInstalledUpdateRecord`），而设备上跑的还是旧版。
        /// 此时 profile-only 只换描述文件、**从不安装** ⇒ 新版本永远装不上，
        /// 而界面（`AppPresentation` 的 `v\(app.version)`）一直显示新版本号。
        ///
        /// 真机复现：把 1.3.20 的 IPA 手动导入 1.3.19 的 Seal ⇒ 落在「已安装」并显示 1.3.20，
        /// 点「续签」直接走 profile-only ⇒ 「关于」里仍是 1.3.19。
        /// 对**第三方**应用不会出现这个问题（它们的记录缺 `signedArtifactStatus`，
        /// 记录通道本来就回落完整重签）—— 只有 Seal 自己走「运行产物身份」这条第二通道。
        case pendingSelfUpdateSource
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

    /// profile-only 的**执行前提**：本机必须持有「该应用当前使用的那张证书」的私钥，
    /// 且它仍能覆盖一份完整 7 天描述文件寿命。
    ///
    /// 返回 `nil` = 前提成立（可以走快路径）；非 `nil` = **必须回落完整重签**的理由。
    ///
    /// - Parameter certificateSerialNumber: **必须传执行侧真正会用的那个序列号** ——
    ///   `SigningCoordinator.renewProfilesOnly` 用的是 `app.certificateSerialNumber`，
    ///   而**不是**带实时身份兜底的 `effectiveCertificateSerialNumber`。
    ///   两者不同时会出现「准入检查了 A、执行用的是 B」，正是本项目反复踩的
    ///   「上游放行、下游又拦」（`SEAL-PROFILE-361` 就是那个洞）。
    ///
    /// 判据与执行侧**同源**：都用 `SigningCertificateMaterialPolicy.availableCertificate`
    /// ＋ `reuseStatus == .reusable` —— 与 `ApplePortalSigningService.certificateReusable(_:)`
    /// 是同一个口径，所以这里判「不可用」时，执行侧**一定**也会判不可用（不会误拦）。
    ///
    /// ⚠️ 与 `evaluate(app:)` 的分工：那一条判「记录是否完整到足以只换描述文件」，
    /// 这一条判「**本机**是否真的能执行」—— 记录可以完全正确，而本机没有私钥。
    static func localCertificateMaterialBlock(
        secret: AccountSecret,
        certificateSerialNumber: String?
    ) -> FullResignReason? {
        guard let serialNumber = nonBlank(certificateSerialNumber),
              let certificate = SigningCertificateMaterialPolicy.availableCertificate(
                  secret: secret,
                  serialNumber: serialNumber
              ),
              SigningCertificateMaterialPolicy.reuseStatus(certificate) == .reusable else {
            return .missingLocalCertificateMaterial
        }
        return nil
    }

    /// `FullResignReason` 的**可读说明**（只用于日志）。
    ///
    /// 界面文案**不**用这里：界面只认 `missingLocalCertificateMaterial` 一个 case
    ///（见 `AppSigningPresentationHelpers.localCertificateRebuildNote`），
    /// 因为只有它对应「用户下一次点续签会发生什么」。
    static func describe(_ reason: FullResignReason) -> String {
        switch reason {
        case .missingInstalledArtifact: "记录里缺少已安装产物"
        case .incompleteSigningIdentity: "记录里的签名身份不完整"
        case .missingTargetRecord: "记录里缺少签名目标"
        case .missingLocalCertificateMaterial: "本机没有该证书的私钥"
        case .pendingSelfUpdateSource: "已导入的更新源尚未安装"
        }
    }

    /// 「本机是否持有该应用当前证书的私钥」——**界面**用（日志用 `describe(_:)`）。
    ///
    /// **三态而不是 `Bool`**：读不到账号密钥 与「确认没有私钥」的下一步动作完全不同 ——
    /// 前者（Keychain 暂时读不到 / 账号已删）**不能**凭空断言「缺私钥」，只能什么都不说；
    /// 后者才是真的「下一次续签必然完整重签」。
    ///
    /// 用户 2026-09-26 明确要求：首次把 Seal 装到手机上时，本机没有该证书的私钥，
    /// 要在「证书序列号」那里写一句「需要重新签名一次获取本机证书」，
    /// 并让**匹配之后**的续签回到「只更新描述文件、不重装」。
    /// 这条状态就是那句文案的唯一判据（见 `AppSigningPresentationHelpers.localCertificateNote(for:)`）。
    enum LocalCertificateAvailability: Equatable, Sendable {
        /// 没有记录序列号、或读不到该账号的密钥 ⇒ **不显示任何话**（不能凭空断言缺私钥）。
        case undetermined
        /// 本机有该证书的私钥，且剩余寿命足以覆盖一份完整 7 天描述文件。
        case ready
        /// 本机没有该证书的私钥（或私钥在、但证书寿命已不足 7 天）⇒ 下一次续签会完整重签并安装。
        case needsFullResign
    }

    /// 单个应用的「本机证书状态」。**与 `localCertificateMaterialBlock` 同源** ——
    /// 前者是它的界面三态化，不会出现「界面说没事、执行时却抛 334」。
    static func localCertificateAvailability(
        secret: AccountSecret?,
        certificateSerialNumber: String?
    ) -> LocalCertificateAvailability {
        guard let secret, nonBlank(certificateSerialNumber) != nil else { return .undetermined }
        return localCertificateMaterialBlock(
            secret: secret,
            certificateSerialNumber: certificateSerialNumber
        ) == nil ? .ready : .needsFullResign
    }

    /// 把「账号密钥表」映射成「每个**已安装**应用的本机证书状态」。
    ///
    /// 抽成纯函数（不碰 Keychain、不碰网络）才能单测 —— 它的错法只在真机上表现为
    /// 「本该提示却没有提示 / 不该提示却提示」，不会崩、不会编译失败。
    ///
    /// ⚠️ 只算**已安装**的应用：未安装的应用还没走到续签，提示它只会让列表变吵。
    static func availabilityByAppID(
        apps: [AppRecord],
        secretsByAccount: [UUID: AccountSecret]
    ) -> [UUID: LocalCertificateAvailability] {
        var values: [UUID: LocalCertificateAvailability] = [:]
        for app in apps where app.belongsInInstalledList {
            values[app.id] = localCertificateAvailability(
                secret: app.accountID.flatMap { secretsByAccount[$0] },
                certificateSerialNumber: app.certificateSerialNumber
            )
        }
        return values
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
    /// - Parameter runningVersion: `SelfAppMetadata.current()?.version` —— **正在运行的那个包**
    ///   的版本。它与记录里的 `version` 是两件事：记录描述「已导入的源包」，可能更新。
    ///   读不到（空串）时整体放弃，**不猜**（空串会被 `Version.compare` 当成 0，
    ///   与任何真实版本都不等 ⇒ 会误判成「有待安装更新」）。
    ///
    /// ⚠️ 调用方**必须**只在「这确实是该 app 自己的运行包」时调用 —— `SelfAppMetadata.current()`
    /// 读的是 `Bundle.main`，对第三方 App 用它会读成 **Seal 自己**的身份（假阳性）。
    /// 见 `SigningCoordinator.liveProfileOnlyIdentity(for:)`。
    static func liveIdentity(
        installedIdentity: InstalledIdentity?,
        runningVersion: String?,
        app: AppRecord
    ) -> LiveProfileOnlyIdentity? {
        guard let installedIdentity,
              installedIdentity.isComplete,
              let mainTarget = installedIdentity.mainTarget,
              let mappedMainBundleIdentifier = nonBlank(app.mappedBundleIdentifier),
              mainTarget.bundleIdentifier.caseInsensitiveCompare(mappedMainBundleIdentifier) == .orderedSame,
              let profileUUID = nonBlank(mainTarget.profileUUID),
              let serialNumber = nonBlank(mainTarget.signerSerialNumber),
              let teamIdentifier = nonBlank(mainTarget.teamIdentifier),
              let resolvedRunningVersion = nonBlank(runningVersion) else {
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
            targetBundleIdentifiers: targets,
            runningVersion: resolvedRunningVersion
        )
    }

    /// 🔴 **唯一判据**：「记录里描述的那个源包」与「正在运行的那个包」是不是同一个版本。
    ///
    /// `true` = 记录里有一条**已导入但尚未生效**的更新源。
    ///
    /// 为什么必须单独立出来（2026-09-26 用户实测）：这条判断有**两个**消费方 ——
    /// ① 准入（`evaluate(app:liveIdentity:)`：版本不一致就回落完整重签）；
    /// ② 界面（`AppSigningPresentationHelpers.pendingUpdateNote(for:runningVersion:)`：
    ///    在详情页 / 操作抽屉里说明「本次续签会完整重签并安装」）。
    /// 两处各写一份必然漂移成「准入说要做、界面不说」或反过来（本项目最反复的坑）。
    ///
    /// ⚠️ **不能用 `AppRecord.hasPendingSelfUpdateSource` 代替它**：那个标志对 Seal
    /// **永远清不掉** —— 自替换安装成功后进程被系统换掉，清标志的那行
    /// （`SigningCoordinator` 里 `updated.hasPendingSelfUpdateSource = false`）
    /// 走的是普通安装路径；而 `SelfAppRegistrar` 的待安装分支刻意一直保留它。
    /// 版本比较则是**自愈**的：装完新版本后记录版本与运行版本自然相等。
    ///
    /// ⚠️ 两边任一读不出来 ⇒ 返回 `false`（**不声称**有待安装更新）：
    ///   · 准入侧：`liveIdentity.runningVersion` 在 `liveIdentity(...)` 里已被 `nonBlank`
    ///     守卫过 ⇒ 只可能是 `app.version` 为空（记录损坏，现实里不会出现）；
    ///   · 界面侧：读不到运行版本时不能凭空告诉用户「有更新待安装」，
    ///     那会把一次正常的续签说成必须重装（与 R85 的 `.undetermined` 同一条纪律）。
    static func hasPendingUpdateSource(
        recordedVersion: String?,
        runningVersion: String?
    ) -> Bool {
        guard let recorded = nonBlank(recordedVersion),
              let running = nonBlank(runningVersion) else { return false }
        return Version.compare(recorded, running) != .orderedSame
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
    ///
    /// 🔴 **再加一条：记录里的源包版本必须等于正在运行的版本**（2026-09-26，用户实测）。
    /// 覆盖更新刻意把记录写成**新导入包**的版本号（`hasPendingSelfUpdateSource`），
    /// 而设备上跑的还是旧版 ⇒ 此时放行 profile-only 等于宣布「更新已生效」，
    /// 而它只换描述文件、从不安装 ⇒ **新版本永远装不上，界面却一直显示新版本号**。
    /// 版本不一致 ⇒ 回落完整重签（它会用 `app.ipaRelativePath` 里的**新包**重新签名并安装，
    /// 装完记录版本与运行版本重新相等 —— 这条判据**自愈**，不依赖任何「待安装」标志：
    /// Seal 走的是自替换安装，进程会被系统换掉，清标志那行根本轮不到它）。
    static func evaluate(
        app: AppRecord,
        liveIdentity: LiveProfileOnlyIdentity?
    ) -> Decision {
        if let liveIdentity,
           let mappedMainBundleIdentifier = nonBlank(app.mappedBundleIdentifier),
           liveIdentity.mainBundleIdentifier.caseInsensitiveCompare(mappedMainBundleIdentifier)
               == .orderedSame {
            // ⚠️ 比较的是**营销版本**（`CFBundleShortVersionString`）—— 那正是更新通道
            // 判「有没有新版本」用的单位（见 `AGENTS.md` §6）。同版本重建（只换构建号）
            // 不在这里拦：那种情况记录会被 `SelfAppRegistrar` 对齐回运行版本，
            // 而「同版本重建也强制完整重装」会把 1.3.17 那个「续签全都要重装」的坑请回来。
            guard hasPendingUpdateSource(
                recordedVersion: app.version,
                runningVersion: liveIdentity.runningVersion
            ) == false else {
                return .requiresFullResign(.pendingSelfUpdateSource)
            }
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
