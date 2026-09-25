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
