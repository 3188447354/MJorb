import Foundation
import Testing
@testable import Seal

struct AppBundleSigningIdentityReaderTests {
    @Test
    func choosesCMSActualSignerInsteadOfFirstAuthorizedCertificate() throws {
        let serialB = TestDeveloperCertificate.serialNumberHex(der: TestDeveloperCertificate.certificateBDER)
        let fingerprintB = TestDeveloperCertificate.sha256Fingerprint(der: TestDeveloperCertificate.certificateBDER)
        let fixture = try IdentityBundleFixture.make(
            authorizedDERs: [
                TestDeveloperCertificate.certificateADER,
                TestDeveloperCertificate.certificateBDER
            ]
        )
        let reader = AppBundleSigningIdentityReader(
            inspectExecutable: { _ in
                .init(serialNumber: serialB, cmsValid: true, codeDirectoryValid: true)
            }
        )

        let identity = try reader.read(bundleURL: fixture.bundleURL)
        #expect(identity.mainTarget?.signerSerialNumber == serialB)
        #expect(identity.mainTarget?.signerCertificateSHA256 == fingerprintB)
    }

    @Test
    func mainTargetUnreadableWhenExecutableInspectionThrows() throws {
        let fixture = try IdentityBundleFixture.make(
            authorizedDERs: [TestDeveloperCertificate.certificateADER]
        )
        let reader = AppBundleSigningIdentityReader(
            inspectExecutable: { _ in throw IdentityReadFailure.signerMissing }
        )

        let identity = try reader.read(bundleURL: fixture.bundleURL)
        #expect(identity.mainTarget?.status == .unreadable)
        #expect(identity.isComplete == false)
    }

    @Test
    func inconsistentArchitecturesWhenInspectReturnsDifferentSerials() throws {
        let fixture = try IdentityBundleFixture.make(
            authorizedDERs: [TestDeveloperCertificate.certificateADER]
        )
        let reader = AppBundleSigningIdentityReader(
            inspectExecutable: { _ in throw IdentityReadFailure.inconsistentArchitectures }
        )

        let identity = try reader.read(bundleURL: fixture.bundleURL)
        #expect(identity.mainTarget?.status == .inconsistentArchitectures)
        #expect(identity.isComplete == false)
    }

    @Test
    func extensionFailureMakesInstalledIdentityIncomplete() throws {
        let serialA = TestDeveloperCertificate.serialNumberHex(der: TestDeveloperCertificate.certificateADER)
        let fixture = try IdentityBundleFixture.make(
            authorizedDERs: [TestDeveloperCertificate.certificateADER],
            extensionBundleID: "com.example.seal.share"
        )
        let reader = AppBundleSigningIdentityReader(
            inspectExecutable: { url in
                if url.path.contains("PlugIns") {
                    throw IdentityReadFailure.signerMissing
                }
                return .init(serialNumber: serialA, cmsValid: true, codeDirectoryValid: true)
            }
        )

        let identity = try reader.read(bundleURL: fixture.bundleURL)
        #expect(identity.mainTarget?.status == .complete)
        #expect(identity.targets.count == 2)
        #expect(identity.targets.first(where: { $0.kind == .appExtension })?.status == .unreadable)
        #expect(identity.isComplete == false)
    }
}

private struct IdentityBundleFixture {
    let bundleURL: URL

    static func make(
        authorizedDERs: [Data],
        extensionBundleID: String? = nil
    ) throws -> IdentityBundleFixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SealIdentityFixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        let bundleURL = root.appending(path: "Seal.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.seal",
            "CFBundleExecutable": "Seal",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1"
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try infoData.write(to: bundleURL.appending(path: "Info.plist"))

        let profileData = try makeProfileData(authorizedDERs: authorizedDERs)
        try profileData.write(to: bundleURL.appending(path: "embedded.mobileprovision"))

        try Data("main-executable".utf8).write(to: bundleURL.appending(path: "Seal"))

        if let extensionBundleID {
            let plugins = bundleURL.appending(path: "PlugIns", directoryHint: .isDirectory)
            let appex = plugins.appending(path: "Share.appex", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
            let extInfo: [String: Any] = [
                "CFBundleIdentifier": extensionBundleID,
                "CFBundleExecutable": "Share",
                "CFBundleShortVersionString": "1.0.0",
                "CFBundleVersion": "1"
            ]
            let extInfoData = try PropertyListSerialization.data(
                fromPropertyList: extInfo, format: .xml, options: 0
            )
            try extInfoData.write(to: appex.appending(path: "Info.plist"))
            try profileData.write(to: appex.appending(path: "embedded.mobileprovision"))
            try Data("extension-executable".utf8).write(to: appex.appending(path: "Share"))
        }

        return IdentityBundleFixture(bundleURL: bundleURL)
    }

    private static func makeProfileData(authorizedDERs: [Data]) throws -> Data {
        // DeveloperCertificates 必须是真实 DER X.509 证书，SecCertificateCreateWithData 才能解析。
        let certificateEntries = authorizedDERs.map {
            "<data>\($0.base64EncodedString())</data>"
        }.joined()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>UUID</key>
            <string>PROFILE-UUID</string>
            <key>Name</key>
            <string>Seal Profile</string>
            <key>CreationDate</key>
            <date>2026-01-01T00:00:00Z</date>
            <key>ExpirationDate</key>
            <date>2027-01-01T00:00:00Z</date>
            <key>TeamIdentifier</key>
            <array><string>T3432ZHJUF9</string></array>
            <key>Entitlements</key>
            <dict>
                <key>application-identifier</key>
                <string>T3432ZHJUF9.com.example.seal</string>
            </dict>
            <key>DeveloperCertificates</key>
            <array>\(certificateEntries)</array>
        </dict>
        </plist>
        """
        return Data(xml.utf8)
    }
}
