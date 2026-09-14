import Foundation
import Testing
@testable import Seal

struct AuthenticatedAppleAccountTests {
    @Test
    func certificateMaterialsSurviveCreatingANewCertificate() {
        var secret = AccountSecret(
            email: "demo@icloud.com",
            accountIdentifier: "ACCOUNT",
            dsid: "DSID",
            authToken: "TOKEN",
            password: nil,
            certificateP12: Data("old-p12".utf8),
            certificateSerialNumber: "OLD",
            certificateMachineIdentifier: "OldDevice"
        )

        secret.storeCertificateMaterial(
            p12: Data("new-p12".utf8),
            serialNumber: "NEW",
            machineIdentifier: "NewDevice"
        )

        #expect(secret.p12(for: "OLD") == Data("old-p12".utf8))
        #expect(secret.p12(for: "NEW") == Data("new-p12".utf8))
        #expect(secret.activated(for: "OLD", machineIdentifier: "OldDevice")?.certificateSerialNumber == "OLD")
        #expect(secret.activated(for: "OLD", machineIdentifier: "OldDevice")?.certificateP12 == Data("old-p12".utf8))
    }

    @Test
    func selectedTeamIsPersistedWithoutChangingAccountIdentity() throws {
        let secret = AccountSecret(
            email: "demo@icloud.com",
            accountIdentifier: "ACCOUNT",
            dsid: "DSID",
            authToken: "TOKEN",
            password: nil,
            certificateP12: nil,
            certificateSerialNumber: nil,
            certificateMachineIdentifier: nil
        )
        let authenticated = AuthenticatedAppleAccount(
            maskedEmail: "d***@icloud.com",
            accountIdentifier: "ACCOUNT",
            teams: [
                AppleTeamRecord(id: "FREE", name: "Free", isFreeTeam: true),
                AppleTeamRecord(id: "PAID", name: "Paid", isFreeTeam: false)
            ],
            secret: secret,
            verifiedAt: Date(timeIntervalSince1970: 100)
        )

        let record = authenticated.record(
            team: try #require(authenticated.teams.first { $0.id == "PAID" }),
            id: UUID()
        )

        #expect(record.accountIdentifier == "ACCOUNT")
        #expect(record.teamID == "PAID")
        #expect(record.teamName == "Paid")
        #expect(record.isFreeTeam == false)
        #expect(record.status == .verified)
    }
}
