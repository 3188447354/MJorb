import Foundation
import Testing
@testable import Seal

struct SignedIPAIdentityReaderTests {
    @Test
    func candidateRequiresExactMainAndExtensionSigners() throws {
        let serial = TestDeveloperCertificate.serialNumberHex(der: TestDeveloperCertificate.certificateBDER)
        let fixture = try IPAArchiveFixture.signedSeal(
            mainSigner: serial,
            extensionSigner: serial
        )
        let candidate = try SignedIPAIdentityReader(
            bundleReader: fixture.reader
        ).read(ipaData: fixture.data, transactionID: UUID())

        #expect(candidate.targets.count == 2)
        #expect(Set(candidate.targets.map(\.signerSerialNumber)) == [serial])
        #expect(candidate.ipaSHA256.count == 64)
    }

    @Test
    func mismatchedExtensionMakesCandidateInvalid() throws {
        let serial = TestDeveloperCertificate.serialNumberHex(der: TestDeveloperCertificate.certificateBDER)
        let fixture = try IPAArchiveFixture.signedSeal(
            mainSigner: serial,
            extensionSigner: "CCCC"
        )
        #expect(throws: IdentityReadFailure.self) {
            try SignedIPAIdentityReader(bundleReader: fixture.reader)
                .read(ipaData: fixture.data, transactionID: UUID())
        }
    }
}
