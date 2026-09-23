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
}
