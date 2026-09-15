import Foundation
import Testing
@testable import Seal

struct ProvisioningProfileReaderTests {
    @Test
    func readsExpirationDateFromEmbeddedPlist() throws {
        let expiration = Date(timeIntervalSince1970: 2_000_000_000)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["ExpirationDate": expiration],
            format: .xml,
            options: 0
        )
        var profile = Data("binary-prefix".utf8)
        profile.append(plist)
        profile.append(Data("binary-suffix".utf8))

        #expect(try ProvisioningProfileReader().expirationDate(from: profile) == expiration)
    }

    @Test
    func readsSigningIdentityFromEmbeddedPlist() throws {
        let expiration = Date(timeIntervalSince1970: 2_000_000_000)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "ExpirationDate": expiration,
                "TeamIdentifier": ["T3432ZHJUF9"],
                "Entitlements": [
                    "application-identifier": "T3432ZHJUF9.com.mjorb.seal.t3432zhjuf9"
                ]
            ],
            format: .xml,
            options: 0
        )
        var profile = Data("binary-prefix".utf8)
        profile.append(plist)
        profile.append(Data("binary-suffix".utf8))

        let summary = try ProvisioningProfileReader().summary(from: profile)
        #expect(summary.expirationDate == expiration)
        #expect(summary.teamIdentifier == "T3432ZHJUF9")
        #expect(
            summary.applicationIdentifier
                == "T3432ZHJUF9.com.mjorb.seal.t3432zhjuf9"
        )
    }

    @Test
    func rejectsProfileWithoutEmbeddedPlist() {
        #expect(throws: ImportFailure.self) {
            _ = try ProvisioningProfileReader().expirationDate(from: Data([0x01, 0x02]))
        }
    }

    @Test
    func developerCertificateIdentityUsesDERFingerprint() {
        let certificate = ProvisioningProfileReader.developerCertificateIdentity(
            der: Data([0x01, 0x02, 0x03]),
            serialNumber: "0001"
        )
        #expect(certificate.serialNumber == "0001")
        #expect(
            certificate.sha256Fingerprint
                == "039058C6F2C0CB492C533B0A4D14EF77CC0F78ABCCCED5287D84A1A2011CFB81"
        )
    }
}
