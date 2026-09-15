import Foundation
import Testing
@testable import Seal

struct SelfSigningIdentityTests {
    @Test
    func installedIdentityRequiresMainAndEveryExtensionToBeComplete() {
        let complete = InstalledIdentity.fixture(targets: [.mainFixture, .extensionFixture])
        let incomplete = InstalledIdentity.fixture(targets: [.mainFixture, .unknownExtensionFixture])
        #expect(complete.isComplete)
        #expect(incomplete.isComplete == false)
    }

    @Test
    func candidateMatchesOnlyExactTargetSetAndSigner() {
        let installed = InstalledIdentity.fixture(targets: [.mainFixture, .extensionFixture])
        let candidate = CandidateIdentity.fixture(targets: [.mainFixture, .extensionFixture])
        #expect(candidate.matches(installed))
        #expect(candidate.replacingSigner(serialNumber: "OTHER").matches(installed) == false)
    }

    @Test
    func installedIdentityWithoutMainAppIsIncomplete() {
        let identity = InstalledIdentity.fixture(targets: [.extensionFixture])
        #expect(identity.isComplete == false)
    }

    @Test
    func installedIdentityWithReadErrorsIsIncomplete() {
        let identity = InstalledIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/Seal.app"),
            version: "1.0.0",
            buildNumber: "1",
            targets: [.mainFixture, .extensionFixture],
            readErrors: ["failed to read extension"]
        )
        #expect(identity.isComplete == false)
    }

    @Test
    func candidateWithMissingTargetDoesNotMatch() {
        let installed = InstalledIdentity.fixture(targets: [.mainFixture, .extensionFixture])
        let candidate = CandidateIdentity.fixture(targets: [.mainFixture])
        #expect(candidate.matches(installed) == false)
    }

    @Test
    func candidateWithDifferentVersionDoesNotMatch() {
        let installed = InstalledIdentity.fixture(targets: [.mainFixture, .extensionFixture])
        let candidate = CandidateIdentity.fixture(
            targets: [.mainFixture, .extensionFixture],
            version: "2.0.0"
        )
        #expect(candidate.matches(installed) == false)
    }

    @Test
    func candidateWithDifferentBuildNumberDoesNotMatch() {
        let installed = InstalledIdentity.fixture(targets: [.mainFixture, .extensionFixture])
        let candidate = CandidateIdentity.fixture(
            targets: [.mainFixture, .extensionFixture],
            buildNumber: "2"
        )
        #expect(candidate.matches(installed) == false)
    }

    @Test
    func candidateMatchesRegardlessOfTargetOrder() {
        let installed = InstalledIdentity.fixture(targets: [.mainFixture, .extensionFixture])
        let candidate = CandidateIdentity.fixture(targets: [.extensionFixture, .mainFixture])
        #expect(candidate.matches(installed))
    }
}

private extension SignedTargetIdentity {
    static let mainFixture = SignedTargetIdentity(
        kind: .mainApp,
        bundleIdentifier: "com.example.seal",
        teamIdentifier: "T3432ZHJUF9",
        applicationIdentifier: "T3432ZHJUF9.com.example.seal",
        profileUUID: "profile-uuid",
        profileExpirationDate: .distantFuture,
        signerSerialNumber: "ABC123",
        signerCertificateSHA256: String(repeating: "A", count: 64),
        status: .complete
    )

    static let extensionFixture = SignedTargetIdentity(
        kind: .appExtension,
        bundleIdentifier: "com.example.seal.share",
        teamIdentifier: "T3432ZHJUF9",
        applicationIdentifier: "T3432ZHJUF9.com.example.seal.share",
        profileUUID: "profile-uuid",
        profileExpirationDate: .distantFuture,
        signerSerialNumber: "ABC123",
        signerCertificateSHA256: String(repeating: "A", count: 64),
        status: .complete
    )

    static let unknownExtensionFixture = SignedTargetIdentity(
        kind: .appExtension,
        bundleIdentifier: "com.example.seal.share",
        teamIdentifier: "T3432ZHJUF9",
        applicationIdentifier: "T3432ZHJUF9.com.example.seal.share",
        profileUUID: "profile-uuid",
        profileExpirationDate: .distantPast,
        signerSerialNumber: "",
        signerCertificateSHA256: "",
        status: .unreadable
    )
}

private extension InstalledIdentity {
    static func fixture(targets: [SignedTargetIdentity]) -> InstalledIdentity {
        InstalledIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/Seal.app"),
            version: "1.0.0",
            buildNumber: "1",
            targets: targets,
            readErrors: []
        )
    }
}

private extension CandidateIdentity {
    static func fixture(
        targets: [SignedTargetIdentity],
        version: String = "1.0.0",
        buildNumber: String = "1"
    ) -> CandidateIdentity {
        CandidateIdentity(
            transactionID: UUID(),
            ipaSHA256: String(repeating: "B", count: 64),
            version: version,
            buildNumber: buildNumber,
            targets: targets
        )
    }

    func replacingSigner(serialNumber: String) -> CandidateIdentity {
        CandidateIdentity(
            transactionID: transactionID,
            ipaSHA256: ipaSHA256,
            version: version,
            buildNumber: buildNumber,
            targets: targets.map {
                SignedTargetIdentity(
                    kind: $0.kind,
                    bundleIdentifier: $0.bundleIdentifier,
                    teamIdentifier: $0.teamIdentifier,
                    applicationIdentifier: $0.applicationIdentifier,
                    profileUUID: $0.profileUUID,
                    profileExpirationDate: $0.profileExpirationDate,
                    signerSerialNumber: serialNumber,
                    signerCertificateSHA256: $0.signerCertificateSHA256,
                    status: $0.status
                )
            }
        )
    }
}
