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
    func sealAlwaysRequiresTheExistingFullResignRoute() {
        let app = makeEligibleApp(isSeal: true)

        #expect(
            ProfileOnlyRenewalPolicy.evaluate(app: app)
                == .requiresFullResign(.sealSelfReplacement)
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

    private func makeEligibleApp(isSeal: Bool = false) -> AppRecord {
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        let mainBundleID = "com.example.demo.TEAM123456"
        let extensionBundleID = "\(mainBundleID).share"
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
            signingTargets: [
                target(bundleIdentifier: mainBundleID, profileUUID: "MAIN-PROFILE", expiry: expiry),
                target(bundleIdentifier: extensionBundleID, profileUUID: "EXT-PROFILE", expiry: expiry)
            ],
            ipaRelativePath: "Apps/Demo.ipa",
            signedIPARelativePath: "Apps/Demo-Signed.ipa",
            signedIPASHA256: "hash",
            signedArtifactStatus: .installed,
            isSeal: isSeal,
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            extensions: [
                AppExtensionRecord(
                    name: "Share",
                    originalBundleIdentifier: "com.example.demo.share",
                    mappedBundleIdentifier: extensionBundleID,
                    kind: .share,
                    provisioningProfileUUID: "EXT-PROFILE",
                    provisioningProfileExpirationDate: expiry,
                    certificateSerialNumber: "00AABB"
                )
            ]
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
