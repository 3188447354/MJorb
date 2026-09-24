import Testing
@testable import Seal

struct AppExtensionProfileStrategyTests {

    private let originalMain = "com.example.video"
    private let mappedMain = "com.example.video.seal.TEAM123"
    private let mappedShare = "com.example.video.seal.TEAM123.Share"
    private let mappedWidget = "com.example.video.seal.TEAM123.Widget"

    @Test
    func sharedMainProfileOnlySubmitsTheMainAppToApple() {
        let mappings = [
            originalMain: mappedMain,
            "com.example.video.Share": mappedShare,
            "com.example.video.Widget": mappedWidget
        ]

        #expect(
            AppExtensionProfileStrategy.sharedMainProfile.portalMappings(
                from: mappings,
                originalMainBundleID: originalMain
            ) == [originalMain: mappedMain]
        )
    }

    @Test
    func sharedMainProfileValidatesExtensionsAgainstTheMainProfile() {
        #expect(
            AppExtensionProfileStrategy.sharedMainProfile.expectedProfileBundleID(
                for: mappedShare,
                mappedMainBundleID: mappedMain
            ) == mappedMain
        )
    }

    @Test
    func independentProfilesKeepsEveryBundleAsAPortalAndProfileTarget() {
        let mappings = [
            originalMain: mappedMain,
            "com.example.video.Share": mappedShare,
            "com.example.video.Widget": mappedWidget
        ]

        #expect(
            AppExtensionProfileStrategy.independentProfiles.portalMappings(
                from: mappings,
                originalMainBundleID: originalMain
            ) == mappings
        )
        #expect(
            AppExtensionProfileStrategy.independentProfiles.expectedProfileBundleID(
                for: mappedShare,
                mappedMainBundleID: mappedMain
            ) == mappedShare
        )
    }

    @Test
    func sealAlwaysUsesIndependentProfiles() {
        #expect(AppExtensionProfileStrategy.defaultFor(isSeal: false) == .sharedMainProfile)
        #expect(AppExtensionProfileStrategy.defaultFor(isSeal: true) == .independentProfiles)
    }

    @Test
    func legacyAppWithDifferentExtensionProfileMovesToTheSharedDefault() {
        let app = AppRecord(
            originalBundleIdentifier: originalMain,
            name: "Video",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            provisioningProfileUUID: "main-profile",
            ipaRelativePath: "Video.ipa",
            importedAt: .now,
            extensions: [
                AppExtensionRecord(
                    name: "Share",
                    originalBundleIdentifier: "com.example.video.Share",
                    provisioningProfileUUID: "extension-profile"
                )
            ]
        )

        #expect(app.effectiveExtensionProfileStrategy == .sharedMainProfile)
    }

    @Test
    func sharedProfileKeepsTheExtensionAsTheRecordedSigningTarget() {
        let target = SigningTargetRecord(
            binding: ProvisioningProfileBinding(
                bundleIdentifier: mappedMain,
                profileUUID: "shared-profile",
                profileName: "Shared",
                teamIdentifier: "TEAM123",
                creationDate: .now,
                expirationDate: .now.addingTimeInterval(7 * 86_400),
                certificateSerialNumbers: ["1234"],
                deviceIdentifiers: ["device"],
                entitlements: [:]
            ),
            signedBundleIdentifier: mappedShare
        )

        #expect(target.bundleIdentifier == mappedShare)
        #expect(target.profileUUID == "shared-profile")
    }

    @Test
    func sharedProfileBlockerIsNilWhenEveryExtensionEntitlementIsCoveredByTheMainApp() {
        let blocker = AppExtensionProfileStrategy.sharedProfileBlocker(
            mainBundleID: mappedMain,
            entitlementsByBundleID: [
                mappedMain: ["application-identifier", "increased-memory-limit"],
                mappedShare: ["application-identifier"],
                mappedWidget: ["application-identifier", "increased-memory-limit"]
            ]
        )

        #expect(blocker == nil)
    }

    @Test
    func sharedProfileBlockerReportsTheFirstUncoveredExtensionDeterministically() {
        let blocker = AppExtensionProfileStrategy.sharedProfileBlocker(
            mainBundleID: mappedMain,
            entitlementsByBundleID: [
                mappedWidget: ["com.apple.developer.kernel.increased-memory-limit"],
                mappedMain: ["application-identifier"],
                mappedShare: ["com.apple.developer.networking.wifi-info"]
            ]
        )

        // 两个扩展都不被主 App 覆盖 ⇒ 必须稳定地选**字典序最小**的那个，
        // 否则同一份 IPA 的日志会抖、对不上。
        #expect(
            blocker == AppExtensionProfileStrategy.SharedProfileBlocker(
                extensionBundleID: mappedShare,
                entitlements: ["com.apple.developer.networking.wifi-info"]
            )
        )
    }

    @Test
    func sharedProfileBlockerIgnoresExtensionsThatAskForNothingExtra() {
        let blocker = AppExtensionProfileStrategy.sharedProfileBlocker(
            mainBundleID: mappedMain,
            entitlementsByBundleID: [
                mappedMain: [],
                mappedShare: [],
                mappedWidget: []
            ]
        )

        #expect(blocker == nil)
    }

    @Test
    func resolvedForSigningKeepsTheSharedProfileWhenExtensionsAreCovered() {
        #expect(
            AppExtensionProfileStrategy.resolvedForSigning(
                requested: .sharedMainProfile,
                mainBundleID: mappedMain,
                entitlementsByBundleID: [
                    mappedMain: ["com.apple.developer.kernel.increased-memory-limit"],
                    mappedShare: ["com.apple.developer.kernel.increased-memory-limit"]
                ]
            ) == .sharedMainProfile
        )
    }

    @Test
    func resolvedForSigningFallsBackToIndependentProfilesWhenAnExtensionNeedsExtraEntitlements() {
        // 真机实证（构建 27）：LiveContainer 的 LiveProcess 请求 increased-memory-limit，
        // 而主 App 没有声明它 ⇒ 共享主描述文件在签后逐 bundle 校验必报 SEAL-ENTITLEMENT-401。
        #expect(
            AppExtensionProfileStrategy.resolvedForSigning(
                requested: .sharedMainProfile,
                mainBundleID: mappedMain,
                entitlementsByBundleID: [
                    mappedMain: [],
                    mappedShare: ["com.apple.developer.kernel.increased-memory-limit"]
                ]
            ) == .independentProfiles
        )
    }

    @Test
    func resolvedForSigningNeverUpgradesIndependentProfilesToShared() {
        // 只允许「共享 → 独立」这一个方向；反向会静默丢扩展能力，正是这条要防的。
        #expect(
            AppExtensionProfileStrategy.resolvedForSigning(
                requested: .independentProfiles,
                mainBundleID: mappedMain,
                entitlementsByBundleID: [
                    mappedMain: [],
                    mappedShare: ["com.apple.developer.kernel.increased-memory-limit"]
                ]
            ) == .independentProfiles
        )
    }
}
