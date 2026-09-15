import Foundation
import Testing
@testable import Seal

struct AppBundleSigningIdentityReaderTests {
    @Test
    func choosesCMSActualSignerInsteadOfFirstAuthorizedCertificate() throws {
        let fixture = try IdentityBundleFixture.make(
            authorized: [
                .init(serialNumber: "AAAA", sha256Fingerprint: String(repeating: "A", count: 64)),
                .init(serialNumber: "BBBB", sha256Fingerprint: String(repeating: "B", count: 64))
            ]
        )
        let reader = AppBundleSigningIdentityReader(
            inspectExecutable: { _ in
                .init(serialNumber: "BBBB", cmsValid: true, codeDirectoryValid: true)
            }
        )

        let identity = try reader.read(bundleURL: fixture.bundleURL)
        #expect(identity.mainTarget?.signerSerialNumber == "BBBB")
        #expect(identity.mainTarget?.signerCertificateSHA256 == String(repeating: "B", count: 64))
    }

    @Test
    func mainTargetUnreadableWhenExecutableInspectionThrows() throws {
        let fixture = try IdentityBundleFixture.make(authorized: [
            .init(serialNumber: "AAAA", sha256Fingerprint: String(repeating: "A", count: 64))
        ])
        let reader = AppBundleSigningIdentityReader(
            inspectExecutable: { _ in throw IdentityReadFailure.signerMissing }
        )

        let identity = try reader.read(bundleURL: fixture.bundleURL)
        #expect(identity.mainTarget?.status == .unreadable)
        #expect(identity.isComplete == false)
    }

    @Test
    func inconsistentArchitecturesWhenInspectReturnsDifferentSerials() throws {
        let fixture = try IdentityBundleFixture.make(authorized: [
            .init(serialNumber: "AAAA", sha256Fingerprint: String(repeating: "A", count: 64))
        ])
        let reader = AppBundleSigningIdentityReader(
            inspectExecutable: { _ in throw IdentityReadFailure.inconsistentArchitectures }
        )

        let identity = try reader.read(bundleURL: fixture.bundleURL)
        #expect(identity.mainTarget?.status == .inconsistentArchitectures)
        #expect(identity.isComplete == false)
    }

    @Test
    func extensionFailureMakesInstalledIdentityIncomplete() throws {
        let fixture = try IdentityBundleFixture.make(
            authorized: [
                .init(serialNumber: "AAAA", sha256Fingerprint: String(repeating: "A", count: 64))
            ],
            extensionBundleID: "com.example.seal.share"
        )
        let reader = AppBundleSigningIdentityReader(
            inspectExecutable: { url in
                if url.path.contains("PlugIns") {
                    throw IdentityReadFailure.signerMissing
                }
                return .init(serialNumber: "AAAA", cmsValid: true, codeDirectoryValid: true)
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
        authorized: [ProvisioningProfileReader.DeveloperCertificateIdentity],
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

        let profileData = try makeProfileData(authorized: authorized)
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

    private static func makeProfileData(
        authorized: [ProvisioningProfileReader.DeveloperCertificateIdentity]
    ) throws -> Data {
        // 构造最小 XML plist，让 ProvisioningProfileReader 能解析出 DeveloperCertificates
        let certificateEntries = authorized.map {
            "<data>\(Data($0.serialNumber.utf8).base64EncodedString())</data>"
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
