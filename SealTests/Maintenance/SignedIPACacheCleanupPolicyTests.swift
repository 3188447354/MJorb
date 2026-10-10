import Foundation
import Testing
@testable import Seal

struct SignedIPACacheCleanupPolicyTests {
    @Test
    func reclaimsOnlyStableInstalledSignedCache() {
        #expect(SignedIPACacheCleanupPolicy.decision(for: record()) == .reclaimable)
    }

    @Test
    func protectsCacheWhileInstallationOutcomeIsNotStable() {
        var awaiting = record()
        awaiting.signedArtifactStatus = .awaitingVerification
        #expect(SignedIPACacheCleanupPolicy.decision(for: awaiting) == .protected(.awaitingVerification))

        var failed = record()
        failed.signedArtifactStatus = .installFailed
        #expect(SignedIPACacheCleanupPolicy.decision(for: failed) == .protected(.installFailed))

        var pending = record()
        pending.pendingSignedSnapshot = PendingSignedSnapshot(
            expiryDate: nil,
            provisioningProfileUUID: nil,
            provisioningProfileName: nil,
            provisioningProfileCreationDate: nil,
            provisioningProfileExpirationDate: nil,
            certificateSerialNumber: nil,
            signingTargets: [],
            extensionSnapshots: []
        )
        #expect(SignedIPACacheCleanupPolicy.decision(for: pending) == .protected(.pendingTransaction))
    }

    private func record() -> AppRecord {
        AppRecord(
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: "com.example.demo.TEAM123456",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            expiryDate: Date(),
            ipaRelativePath: "Apps/Demo/Original.ipa",
            signedIPARelativePath: "Apps/Demo/Signed.ipa",
            signedIPASHA256: "hash",
            signedArtifactStatus: .installed,
            importedAt: Date()
        )
    }
}
