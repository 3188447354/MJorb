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

    @Test
    func liveIdentityForADifferentBundleIdentifierDoesNotAdmitTheRecord() {
        // `SelfAppMetadata.current()` 读的是 `Bundle.main` —— 若被误用到第三方 App 上，
        // 主目标 Bundle ID 会对不上。这一条钉住「对不上就不放行」。
        let app = makeSealRecordAsWrittenBySelfAppRegistrar()
        let foreign = ProfileOnlyRenewalPolicy.liveIdentity(
            installedIdentity: installedIdentity(bundleIdentifier: "com.other.app.TEAM999999"),
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
            ProfileOnlyRenewalPolicy.liveIdentity(installedIdentity: incomplete, app: app) == nil
        )
    }

    @Test
    func liveIdentityPathDoesNotRequireAPersistedDeviceBinding() {
        // Seal 的记录里从来没有 `signedDeviceIdentifier`（`SelfAppRegistrar` 不写它，
        // 也不该编造一个）⇒ 实时身份通道下不能要求它匹配。
        let app = makeSealRecordAsWrittenBySelfAppRegistrar()
        let live = ProfileOnlyRenewalPolicy.liveIdentity(
            installedIdentity: installedIdentity(bundleIdentifier: "com.example.demo.TEAM123456"),
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
            targetBundleIdentifiers: ["com.example.demo.TEAM123456"]
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
