import Foundation
import Testing
@testable import Seal

struct SigningCertificateMaterialPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func externalSealCanEstablishNewIdentityOnlyForItsRunningTeam() {
        #expect(SigningCertificateMaterialPolicy.externalSealSerial(
            isSeal: true, teamID: "TEAM", runningTeamID: "TEAM", runningSerials: ["0AA11"], remoteSerials: ["AA11"], localPrivateKeySerials: [], expectedSerialNumber: "AA11"
        ) == "AA11")
        #expect(SigningCertificateMaterialPolicy.externalSealSerial(
            isSeal: true, teamID: "TEAM", runningTeamID: "TEAM", runningSerials: ["AA11"], remoteSerials: ["AA11", "BB22"], localPrivateKeySerials: [], expectedSerialNumber: "BB22"
        ) == nil)
        #expect(SigningCertificateMaterialPolicy.externalSealSerial(
            isSeal: true, teamID: "TEAM", runningTeamID: "TEAM", runningSerials: ["0AA11"], remoteSerials: ["AA11"], localPrivateKeySerials: []
        ) == "AA11")
        #expect(SigningCertificateMaterialPolicy.externalSealSerial(
            isSeal: false, teamID: "TEAM", runningTeamID: "TEAM", runningSerials: ["AA11"], remoteSerials: ["AA11"], localPrivateKeySerials: []
        ) == nil)
        #expect(SigningCertificateMaterialPolicy.externalSealSerial(
            isSeal: true, teamID: "OTHER", runningTeamID: "TEAM", runningSerials: ["AA11"], remoteSerials: ["AA11"], localPrivateKeySerials: []
        ) == nil)
        #expect(SigningCertificateMaterialPolicy.externalSealSerial(
            isSeal: true, teamID: "TEAM", runningTeamID: "TEAM", runningSerials: ["AA11"], remoteSerials: ["AA11"], localPrivateKeySerials: ["0AA11"]
        ) == nil)
        #expect(SigningCertificateMaterialPolicy.externalSealSerial(
            isSeal: true, teamID: "TEAM", runningTeamID: "TEAM", runningSerials: [], remoteSerials: ["AA11"], localPrivateKeySerials: []
        ) == nil)
    }

    @Test
    func lifetimeMustCoverAnEntireNewProfile() {
        let minimum = SigningCertificateMaterialPolicy.minimumRemainingLifetime
        #expect(SigningCertificateMaterialPolicy.reuseStatus(validity: nil, now: now) == .invalidValidity)
        #expect(SigningCertificateMaterialPolicy.reuseStatus(
            validity: X509CertificateValidity(notBefore: now.addingTimeInterval(-100), notAfter: now.addingTimeInterval(minimum)), now: now
        ) == .insufficientLifetime)
        #expect(SigningCertificateMaterialPolicy.reuseStatus(
            validity: X509CertificateValidity(notBefore: now.addingTimeInterval(-100), notAfter: now.addingTimeInterval(minimum + 1)), now: now
        ) == .reusable)
        #expect(SigningCertificateMaterialPolicy.reuseStatus(
            validity: X509CertificateValidity(notBefore: now.addingTimeInterval(100), notAfter: now.addingTimeInterval(minimum + 1000)), now: now
        ) == .invalidValidity)
    }

    @Test
    func missingOrCorruptP12DoesNotCountAsLocalPrivateKey() {
        var secret = AccountSecret(email: "test@example.invalid", accountIdentifier: "test", dsid: "test", authToken: "test", password: nil)
        #expect(SigningCertificateMaterialPolicy.availableCertificate(secret: secret, serialNumber: "AA11") == nil)
        secret.storeCertificateMaterial(p12: Data([0, 1, 2]), serialNumber: "AA11", machineIdentifier: nil)
        #expect(SigningCertificateMaterialPolicy.availableCertificate(secret: secret, serialNumber: "0AA11") == nil)
    }

    @Test
    func reauthenticationPreservesHistoricalSigningMaterial() {
        var old = AccountSecret(email: "test@example.invalid", accountIdentifier: "test", dsid: "old", authToken: "old", password: nil)
        old.storeCertificateMaterial(p12: Data([1]), serialNumber: "AA11", machineIdentifier: "a")
        old.storeCertificateMaterial(p12: Data([2]), serialNumber: "BB22", machineIdentifier: "b")
        let authenticated = AccountSecret(email: "test@example.invalid", accountIdentifier: "test", dsid: "new", authToken: "new", password: nil)
        let merged = authenticated.preservingSigningMaterial(from: old)
        #expect(merged.authToken == "new")
        #expect(merged.p12(for: "0AA11") == Data([1]))
        #expect(merged.p12(for: "BB22") == Data([2]))
        #expect(merged.machineIdentifier(for: "AA11") == "a")
        let other = AccountSecret(email: "other@example.invalid", accountIdentifier: "other", dsid: "new", authToken: "new", password: nil)
        #expect(other.preservingSigningMaterial(from: old).certificateP12BySerial.isEmpty)
    }
}
