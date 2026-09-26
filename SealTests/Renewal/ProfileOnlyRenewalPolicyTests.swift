import Foundation
import Testing
@testable import Seal

struct ProfileOnlyRenewalPolicyTests {

    @Test
    func missingPortalAppIDRequiresFullResignInsteadOfRegistration() {
        #expect(
            ProfileOnlyRenewalPolicy.portalAppIDDecision(isPresent: false)
                == .requiresFullResign
        )
    }

    @Test
    func existingPortalAppIDCanBeReused() {
        #expect(
            ProfileOnlyRenewalPolicy.portalAppIDDecision(isPresent: true)
                == .reuse
        )
    }

    @Test
    func sealIsEligibleForProfileOnlyLikeAnyThirdPartyApp() {
        // 回归钉（2026-09-25 真机，构建 44）：旧实现第一句就**按身份**排除 Seal
        // （`guard app.isSeal == false else { return .requiresFullResign(.sealSelfReplacement) }`）
        // ⇒ Seal 续签**永远**走完整重签 + 自替换安装 ⇒ 进程被系统换掉：
        // 批量续签队列项留在 `running` 变成未知（`SEAL-RENEW-007`）、
        // 自替换安装报 `SEAL-SELF-109`、用户必须手动重试。
        // 判定依据是**记录是否完整**，与「这是谁的应用」无关 —— 上游 SideStore 的
        // `refresh` 管线对它自己也只注入描述文件、从不重签重装。
        let app = makeEligibleApp(isSeal: true)

        #expect(
            ProfileOnlyRenewalPolicy.evaluate(app: app)
                == .eligible(
                    targetBundleIdentifiers: [
                        "com.example.demo.TEAM123456",
                        "com.example.demo.TEAM123456.share"
                    ]
                )
        )
    }

    @Test
    func sealWithIncompleteRecordStillRequiresFullResign() {
        // 反方向：去掉「按身份一刀切」**不是**后门 —— 记录不完整时 Seal 照旧回落完整重签。
        var app = makeEligibleApp(isSeal: true)
        app.accountID = nil

        #expect(
            ProfileOnlyRenewalPolicy.evaluate(app: app)
                == .requiresFullResign(.incompleteSigningIdentity)
        )
    }

    @Test
    func installedThirdPartyAppWithoutExtensionsIsEligible() {
        let app = makeEligibleApp(includeExtension: false)

        #expect(
            ProfileOnlyRenewalPolicy.evaluate(app: app)
                == .eligible(
                    targetBundleIdentifiers: ["com.example.demo.TEAM123456"]
                )
        )
    }

    @Test
    func installedThirdPartyAppWithCompleteMainAndExtensionTargetsIsEligible() {
        let app = makeEligibleApp()

        #expect(
            ProfileOnlyRenewalPolicy.evaluate(app: app)
                == .eligible(
                    targetBundleIdentifiers: [
                        "com.example.demo.TEAM123456",
                        "com.example.demo.TEAM123456.share"
                    ]
                )
        )
    }

    @Test
    func eligibilityDoesNotDependOnTheExtensionProfileStrategy() {
        // 回归钉（2026-09-24 真机）：曾经按「共享主描述文件 + 含扩展 ⇒ 完整重签」一刀切，
        // 把含扩展应用的快路径整个丢掉 —— 抖音续签从「仅更新描述文件」变成
        // 658 MB 完整重签 + 安装（约 4 分钟）。准入判据**不再看策略**：
        // 共享/独立由**续签侧**按记录里的实际策略分流（`prepareProfileOnlyRenewal`）。
        for strategy in AppExtensionProfileStrategy.allCases {
            var app = makeEligibleApp()
            app.extensionProfileStrategy = strategy

            #expect(
                ProfileOnlyRenewalPolicy.evaluate(app: app)
                    == .eligible(
                        targetBundleIdentifiers: [
                            "com.example.demo.TEAM123456",
                            "com.example.demo.TEAM123456.share"
                        ]
                    )
            )
        }
    }

    @Test
    func missingExtensionTargetRequiresTheExistingFullResignRoute() {
        var app = makeEligibleApp()
        app.signingTargets.removeAll {
            $0.bundleIdentifier == "com.example.demo.TEAM123456.share"
        }

        #expect(
            ProfileOnlyRenewalPolicy.evaluate(app: app)
                == .requiresFullResign(.missingTargetRecord)
        )
    }

    @Test
    func missingOwningAccountRequiresTheExistingFullResignRoute() {
        var app = makeEligibleApp()
        app.accountID = nil

        #expect(
            ProfileOnlyRenewalPolicy.evaluate(app: app)
                == .requiresFullResign(.incompleteSigningIdentity)
        )
    }

    @Test
    func staleMainProfileSnapshotRequiresTheExistingFullResignRoute() {
        var app = makeEligibleApp()
        app.provisioningProfileUUID = "STALE-MAIN-PROFILE"

        #expect(
            ProfileOnlyRenewalPolicy.evaluate(app: app)
                == .requiresFullResign(.missingTargetRecord)
        )
    }

    // MARK: - 运行产物实时身份通道（R84，2026-09-26 构建 46 真机）

    /// 🔴 本组是 R84 的**核心回归钉**：记录不完整但运行包能自证身份时必须放行。
    ///
    /// Seal 自身的记录由 `SelfAppRegistrar` 维护，它**从不写** `signedDeviceIdentifier` /
    /// `signingTargets` / `signedIPARelativePath`（⇒ `hasSignedArtifact` 恒为 false）
    /// ⇒ 只认记录的准入在真机上**一次都没放行过 Seal**：每次续签都走完整重签 ＋ 自替换。
    @Test
    func liveIdentityAdmitsAnAppWhoseRecordIsIncomplete() {
        // 完全按 `SelfAppRegistrar` 写出来的形态造记录：没有任何「已装产物」字段。
        let app = makeSealRecordAsWrittenBySelfAppRegistrar()
        let live = ProfileOnlyRenewalPolicy.liveIdentity(
            installedIdentity: installedIdentity(bundleIdentifier: "com.example.demo.TEAM123456"),
            runningVersion: app.version,
            app: app
        )

        #expect(live != nil)
        #expect(
            ProfileOnlyRenewalPolicy.evaluate(app: app, liveIdentity: live)
                == .eligible(targetBundleIdentifiers: ["com.example.demo.TEAM123456"])
        )
        // 没有实时身份时，同一条记录必须照旧回落完整重签（**不是**后门）。
        #expect(
            ProfileOnlyRenewalPolicy.evaluate(app: app, liveIdentity: nil)
                == .requiresFullResign(.missingInstalledArtifact)
        )
    }

    // MARK: - 「已导入的更新源尚未安装」（R89，2026-09-26 用户实测）

    /// 🔴 用户原话：「我是将 1.3.20 直接导入 1.3.19 的 seal 里……点续签是直接续签了，
    /// 但是关于里还是 1.3.19 —— 是不是续签的还是 1.3.19、显示的是 1.3.20」。
    ///
    /// 根因：覆盖更新（`ImportWorkflow.makeSelfUpdateRecord`）刻意把记录写成**新导入包**的
    /// 版本号（并置 `hasPendingSelfUpdateSource`），而设备上跑的还是旧版；而实时身份通道
    /// 原先只比对 **Bundle ID 相等** ⇒ 放行 profile-only（只换描述文件、**从不安装**）
    /// ⇒ 新版本永远装不上，界面却一直显示新版本号。
    @Test
    func liveIdentityRefusesProfileOnlyWhileAnImportedUpdateIsNotInstalledYet() {
        let app = makeSealRecordAsWrittenBySelfAppRegistrar()
        // 记录里是新导入的源包版本，而正在跑的仍是旧版 —— 这正是覆盖更新后的窗口。
        let stale = ProfileOnlyRenewalPolicy.liveIdentity(
            installedIdentity: installedIdentity(bundleIdentifier: "com.example.demo.TEAM123456"),
            runningVersion: "1.3.16",
            app: app
        )

        #expect(stale != nil)
        #expect(
            ProfileOnlyRenewalPolicy.evaluate(app: app, liveIdentity: stale)
                == .requiresFullResign(.pendingSelfUpdateSource)
        )

        // 反过来：版本一致（更新已经装上）时必须回到快路径 —— 否则会把
        // 「每次续签都要重装」请回来（1.3.17 那个坑）。
        let sameVersion = ProfileOnlyRenewalPolicy.liveIdentity(
            installedIdentity: installedIdentity(bundleIdentifier: "com.example.demo.TEAM123456"),
            runningVersion: app.version,
            app: app
        )
        #expect(
            ProfileOnlyRenewalPolicy.evaluate(app: app, liveIdentity: sameVersion)
                == .eligible(targetBundleIdentifiers: ["com.example.demo.TEAM123456"])
        )
    }

    /// 判据本身的三态：**两边都读得出、且语义化相等**才算「没有待安装更新」；
    /// 任一边读不出来时返回 `false`（不声称）而不是 `true`（猜成有待安装）——
    /// 后者会把一次正常的续签说成必须重装。
    @Test
    func pendingUpdateSourceIsClaimedOnlyWhenBothVersionsAreComparable() {
        #expect(
            ProfileOnlyRenewalPolicy.hasPendingUpdateSource(
                recordedVersion: "1.3.20",
                runningVersion: "1.3.19"
            )
        )
        // `v` 前缀与补零都算同一版本（`Version.compare` 的语义化比较）。
        #expect(
            ProfileOnlyRenewalPolicy.hasPendingUpdateSource(
                recordedVersion: "v1.3.20",
                runningVersion: "1.3.20.0"
            ) == false
        )
        #expect(
            ProfileOnlyRenewalPolicy.hasPendingUpdateSource(
                recordedVersion: "1.3.20",
                runningVersion: "1.3.20"
            ) == false
        )
        #expect(
            ProfileOnlyRenewalPolicy.hasPendingUpdateSource(
                recordedVersion: nil,
                runningVersion: "1.3.20"
            ) == false
        )
        #expect(
            ProfileOnlyRenewalPolicy.hasPendingUpdateSource(
                recordedVersion: "1.3.20",
                runningVersion: nil
            ) == false
        )
        #expect(
            ProfileOnlyRenewalPolicy.hasPendingUpdateSource(
                recordedVersion: "   ",
                runningVersion: "1.3.20"
            ) == false
        )
    }

    /// 版本不一致时，实时身份**仍然**必须能构造出来 —— 否则会退化成
    /// 「回落记录通道」，而记录通道对 Seal 恒判 `.missingInstalledArtifact`，
    /// 归因就从「有更新没装」变成「记录里缺少已安装产物」（日志会误导排查）。
    @Test
    func aPendingUpdateStillReadsTheRunningIdentityInsteadOfFallingBack() {
        let app = makeSealRecordAsWrittenBySelfAppRegistrar()
        let live = ProfileOnlyRenewalPolicy.liveIdentity(
            installedIdentity: installedIdentity(bundleIdentifier: "com.example.demo.TEAM123456"),
            runningVersion: "1.3.16",
            app: app
        )

        #expect(live?.runningVersion == "1.3.16")
        #expect(
            ProfileOnlyRenewalPolicy.evaluate(app: app, liveIdentity: nil)
                != .requiresFullResign(.pendingSelfUpdateSource)
        )
    }

    @Test
    func liveIdentityForADifferentBundleIdentifierDoesNotAdmitTheRecord() {
        // `SelfAppMetadata.current()` 读的是 `Bundle.main` —— 若被误用到第三方 App 上，
        // 主目标 Bundle ID 会对不上。这一条钉住「对不上就不放行」。
        let app = makeSealRecordAsWrittenBySelfAppRegistrar()
        let foreign = ProfileOnlyRenewalPolicy.liveIdentity(
            installedIdentity: installedIdentity(bundleIdentifier: "com.other.app.TEAM999999"),
            runningVersion: app.version,
            app: app
        )

        #expect(foreign == nil)
        #expect(
            ProfileOnlyRenewalPolicy.evaluate(app: app, liveIdentity: foreign)
                == .requiresFullResign(.missingInstalledArtifact)
        )
    }

    @Test
    func incompleteLiveIdentityIsNeverAnAdmissionTicket() {
        // 半份身份（主程序读不出来）不能当准入依据 —— 与 `CertificateCleanupPolicy`
        // 的 `identityConfidence` 同口径：读不出 Seal 的真实签名者时，高风险操作整体关闭。
        let app = makeSealRecordAsWrittenBySelfAppRegistrar()
        let incomplete = InstalledIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/Seal.app"),
            version: "1.3.17",
            buildNumber: "47",
            targets: [],
            readErrors: ["主程序 CMS 读取失败"]
        )

        #expect(
            ProfileOnlyRenewalPolicy.liveIdentity(
                installedIdentity: incomplete,
                runningVersion: app.version,
                app: app
            ) == nil
        )
    }

    /// 运行版本读不出来时**整体放弃**（返回 `nil`），不猜 —— 空串会被 `Version.compare`
    /// 当成 0，与任何真实版本都不等 ⇒ 会被误判成「有待安装更新」而把快路径关掉。
    @Test
    func unreadableRunningVersionIsNeverAnAdmissionTicket() {
        let app = makeSealRecordAsWrittenBySelfAppRegistrar()

        #expect(
            ProfileOnlyRenewalPolicy.liveIdentity(
                installedIdentity: installedIdentity(bundleIdentifier: "com.example.demo.TEAM123456"),
                runningVersion: nil,
                app: app
            ) == nil
        )
        #expect(
            ProfileOnlyRenewalPolicy.liveIdentity(
                installedIdentity: installedIdentity(bundleIdentifier: "com.example.demo.TEAM123456"),
                runningVersion: "   ",
                app: app
            ) == nil
        )
    }

    @Test
    func liveIdentityPathDoesNotRequireAPersistedDeviceBinding() {
        // Seal 的记录里从来没有 `signedDeviceIdentifier`（`SelfAppRegistrar` 不写它，
        // 也不该编造一个）⇒ 实时身份通道下不能要求它匹配。
        let app = makeSealRecordAsWrittenBySelfAppRegistrar()
        let live = ProfileOnlyRenewalPolicy.liveIdentity(
            installedIdentity: installedIdentity(bundleIdentifier: "com.example.demo.TEAM123456"),
            runningVersion: app.version,
            app: app
        )

        #expect(
            ProfileOnlyRenewalPolicy.isBoundToCurrentDevice(
                app: app,
                deviceIdentifier: "ANY-DEVICE",
                liveIdentity: live
            )
        )
        // 记录通道**不放松**：没有实时身份时，设备绑定必须真的匹配。
        #expect(
            ProfileOnlyRenewalPolicy.isBoundToCurrentDevice(
                app: app,
                deviceIdentifier: "ANY-DEVICE",
                liveIdentity: nil
            ) == false
        )
    }

    @Test
    func effectiveCertificateSerialNumberFallsBackToTheLiveIdentity() {
        var app = makeEligibleApp()
        app.certificateSerialNumber = nil
        let live = LiveProfileOnlyIdentity(
            mainBundleIdentifier: "com.example.demo.TEAM123456",
            profileUUID: "MAIN-PROFILE",
            certificateSerialNumber: "00AABB",
            teamIdentifier: "TEAM123456",
            targetBundleIdentifiers: ["com.example.demo.TEAM123456"],
            runningVersion: "1.0"
        )

        #expect(
            ProfileOnlyRenewalPolicy.effectiveCertificateSerialNumber(app: app, liveIdentity: live)
                == "00AABB"
        )
        #expect(
            ProfileOnlyRenewalPolicy.effectiveCertificateSerialNumber(app: app, liveIdentity: nil)
                == nil
        )
    }

    // MARK: - 本机证书材料状态（R85，2026-09-26 构建 48 真机）

    /// 用户 2026-09-26 的真机诉求：首次把 Seal 装到手机上时本机没有该证书的私钥，
    /// 要在「证书序列号」那里写一句「需要重新签名一次获取本机证书」，
    /// 并让**匹配之后**的续签回到「只更新描述文件、不重装」。
    ///
    /// 这条钉住「什么时候该说这句话」的判据 —— 与准入的最后一道闸门
    ///（`SigningCoordinator.shouldUseProfileOnlyRenewal` 里的 `localCertificateMaterialBlock`）
    /// **同源**，所以不会出现「界面说没事、执行时却抛 `SEAL-PROFILE-334`」。
    @Test
    func missingLocalPrivateKeyIsReportedAsNeedingAFullResign() {
        // 记录里有序列号、账号密钥也能读到，但**本机没有这张证书的私钥**
        // —— 正是构建 48 日志里 `本机有私钥 0 张` 的形态（重装 Seal 会清空 Keychain）。
        let secret = AccountSecret(
            email: "test@example.invalid",
            accountIdentifier: "test",
            dsid: "test",
            authToken: "test",
            password: nil
        )
        #expect(
            ProfileOnlyRenewalPolicy.localCertificateAvailability(
                secret: secret,
                certificateSerialNumber: "00AABB"
            ) == .needsFullResign
        )
        // 私钥材料**存在但解析不出来**（旧账号遗留 / 数据损坏）同样按「没有私钥」处理 ——
        // 与 `SigningCertificateMaterialPolicy.availableCertificate` 同口径。
        // ⚠️ 反向的 `.ready`（真有可复用私钥）需要一份**真实 PKCS#12 夹具**，
        //    本仓没有这种夹具（`ALTCertificate(p12Data:)` 解析不了合成数据）⇒ 那一支
        //    只能由真机验证覆盖；这里至少钉死「坏材料绝不被当成可用私钥」。
        var corrupt = secret
        corrupt.storeCertificateMaterial(
            p12: Data([0, 1, 2]),
            serialNumber: "00AABB",
            machineIdentifier: nil
        )
        #expect(
            ProfileOnlyRenewalPolicy.localCertificateAvailability(
                secret: corrupt,
                certificateSerialNumber: "00AABB"
            ) == .needsFullResign
        )
    }

    @Test
    func unreadableSecretOrMissingSerialIsNeverReportedAsMissingPrivateKey() {
        // 三态的意义：读不到账号密钥 / 记录里没有序列号时，**不能**替用户断言「你没有证书」——
        // 那会把「Keychain 暂时读不到」说成「证书没了」，把用户送去重签一次本来不需要重签的续签。
        let secret = AccountSecret(
            email: "test@example.invalid",
            accountIdentifier: "test",
            dsid: "test",
            authToken: "test",
            password: nil
        )
        #expect(
            ProfileOnlyRenewalPolicy.localCertificateAvailability(
                secret: nil,
                certificateSerialNumber: "00AABB"
            ) == .undetermined
        )
        #expect(
            ProfileOnlyRenewalPolicy.localCertificateAvailability(
                secret: secret,
                certificateSerialNumber: nil
            ) == .undetermined
        )
        #expect(
            ProfileOnlyRenewalPolicy.localCertificateAvailability(
                secret: secret,
                certificateSerialNumber: "   "
            ) == .undetermined
        )
    }

    @Test
    func availabilityIsComputedOnlyForInstalledAppsAndByTheirOwnAccount() {
        // 两条约束：
        //   ① 只算**已安装**的应用 —— 未安装的还没走到续签，提示它只会让列表变吵；
        //   ② 账号必须按**该应用自己**的 `accountID` 查 —— 用「第一个可用账号」会在
        //      多账号设备上给出错误提示（本项目「悬空引用」那一族坑的同一种错法）。
        let accountA = UUID()
        var installed = makeEligibleApp()
        installed.accountID = accountA
        // 未安装：`belongsInInstalledList` 的四个来源全部为假。
        var signed = makeEligibleApp()
        signed.state = .signed
        signed.signedArtifactStatus = nil
        signed.lastInstalledAt = nil
        signed.accountID = accountA
        // 记录里的账号在账号库里**不存在**（删过 Apple ID）⇒ 读不到密钥。
        var danglingAccount = makeEligibleApp()
        danglingAccount.accountID = UUID()

        let values = ProfileOnlyRenewalPolicy.availabilityByAppID(
            apps: [installed, signed, danglingAccount],
            secretsByAccount: [
                accountA: AccountSecret(
                    email: "a@example.invalid",
                    accountIdentifier: "a",
                    dsid: "a",
                    authToken: "a",
                    password: nil
                )
            ]
        )

        #expect(values[installed.id] == .needsFullResign)
        #expect(values[signed.id] == nil)
        #expect(values[danglingAccount.id] == .undetermined)
    }

    // MARK: - Fixtures

    /// 造一条**完全按 `SelfAppRegistrar.atomicallyUpdateSealRecord` 写出来**的 Seal 记录：
    /// 没有 `signedIPARelativePath` / `signedIPASHA256` / `signedDeviceIdentifier` /
    /// `signingTargets`，`signedArtifactStatus` 为 nil。
    ///
    /// ⚠️ 测试里构造的「记录」必须按真实写入路径造，否则判据在 CI 上是绿的、
    /// 在真机上是错的（本项目已踩过同族坑：单测里造错的设备端数据只在 CI 红）。
    private func makeSealRecordAsWrittenBySelfAppRegistrar() -> AppRecord {
        AppRecord(
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: "com.example.demo.TEAM123456",
            name: "Seal",
            version: "1.3.17",
            buildNumber: "47",
            size: 1,
            state: .installed,
            expiryDate: Date(timeIntervalSince1970: 1_900_000_000),
            accountID: UUID(),
            signingTeamID: "TEAM123456",
            certificateSerialNumber: "00AABB",
            provisioningProfileUUID: "MAIN-PROFILE",
            provisioningProfileExpirationDate: Date(timeIntervalSince1970: 1_900_000_000),
            ipaRelativePath: "Apps/Seal.ipa",
            isSeal: true,
            isPinned: true,
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            extensions: []
        )
    }

    private func installedIdentity(bundleIdentifier: String) -> InstalledIdentity {
        InstalledIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/Seal.app"),
            version: "1.3.17",
            buildNumber: "47",
            targets: [
                SignedTargetIdentity(
                    kind: .mainApp,
                    bundleIdentifier: bundleIdentifier,
                    teamIdentifier: "TEAM123456",
                    applicationIdentifier: "TEAM123456.com.example.demo",
                    profileUUID: "MAIN-PROFILE",
                    profileExpirationDate: Date(timeIntervalSince1970: 1_900_000_000),
                    signerSerialNumber: "00AABB",
                    signerCertificateSHA256: "sha",
                    status: .complete
                )
            ],
            readErrors: []
        )
    }

    private func makeEligibleApp(isSeal: Bool = false, includeExtension: Bool = true) -> AppRecord {
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        let mainBundleID = "com.example.demo.TEAM123456"
        let extensionBundleID = "\(mainBundleID).share"
        var targets = [
            target(bundleIdentifier: mainBundleID, profileUUID: "MAIN-PROFILE", expiry: expiry)
        ]
        var extensions: [AppExtensionRecord] = []
        if includeExtension {
            targets.append(
                target(bundleIdentifier: extensionBundleID, profileUUID: "EXT-PROFILE", expiry: expiry)
            )
            extensions.append(
                AppExtensionRecord(
                    name: "Share",
                    originalBundleIdentifier: "com.example.demo.share",
                    mappedBundleIdentifier: extensionBundleID,
                    kind: .share,
                    provisioningProfileUUID: "EXT-PROFILE",
                    provisioningProfileExpirationDate: expiry,
                    certificateSerialNumber: "00AABB"
                )
            )
        }
        return AppRecord(
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: mainBundleID,
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            expiryDate: expiry,
            accountID: UUID(),
            signingTeamID: "TEAM123456",
            certificateSerialNumber: "00AABB",
            signedDeviceIdentifier: "DEVICE-UDID",
            provisioningProfileUUID: "MAIN-PROFILE",
            provisioningProfileExpirationDate: expiry,
            signingTargets: targets,
            ipaRelativePath: "Apps/Demo.ipa",
            signedIPARelativePath: "Apps/Demo-Signed.ipa",
            signedIPASHA256: "hash",
            signedArtifactStatus: .installed,
            isSeal: isSeal,
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            extensions: extensions
        )
    }

    private func target(
        bundleIdentifier: String,
        profileUUID: String,
        expiry: Date
    ) -> SigningTargetRecord {
        SigningTargetRecord(
            bundleIdentifier: bundleIdentifier,
            profileUUID: profileUUID,
            profileName: nil,
            profileCreationDate: nil,
            profileExpirationDate: expiry,
            teamIdentifier: "TEAM123456",
            certificateSerialNumbers: ["00AABB"],
            deviceIdentifiers: ["DEVICE-UDID"],
            entitlementKeys: []
        )
    }
}
