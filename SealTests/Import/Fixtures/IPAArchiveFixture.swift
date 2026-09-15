import Foundation
import ZIPFoundation
@testable import Seal

enum IPAArchiveFixture {
    struct AppSpec {
        let directoryName: String
        let bundleIdentifier: String
        let name: String
        let version: String
        let buildNumber: String
        let malformedInfo: Bool

        init(
            directoryName: String = "Demo.app",
            bundleIdentifier: String = "com.example.demo",
            name: String = "Demo",
            version: String = "1.2.3",
            buildNumber: String = "45",
            malformedInfo: Bool = false
        ) {
            self.directoryName = directoryName
            self.bundleIdentifier = bundleIdentifier
            self.name = name
            self.version = version
            self.buildNumber = buildNumber
            self.malformedInfo = malformedInfo
        }
    }

    static func make(
        apps: [AppSpec] = [AppSpec()],
        includeInfo: Bool = true,
        includeIcon: Bool = true,
        includeShareExtension: Bool = false,
        includeEntitlements: Bool = false,
        includeMobileProvision: Bool = false,
        extraEntries: [(path: String, data: Data)] = []
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "SealTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archiveURL = directory.appending(path: "Fixture.ipa")
        let archive = try Archive(url: archiveURL, accessMode: .create)

        for app in apps {
            let appRoot = "Payload/\(app.directoryName)"
            if includeInfo {
                let infoData: Data
                if app.malformedInfo {
                    infoData = Data("not a property list".utf8)
                } else {
                    infoData = try propertyListData([
                        "CFBundleDisplayName": app.name,
                        "CFBundleIdentifier": app.bundleIdentifier,
                        "CFBundleShortVersionString": app.version,
                        "CFBundleVersion": app.buildNumber,
                        "CFBundleIcons": [
                            "CFBundlePrimaryIcon": [
                                "CFBundleIconFiles": ["AppIcon60x60"]
                            ]
                        ]
                    ])
                }
                try add(infoData, path: "\(appRoot)/Info.plist", to: archive)
            }

            if includeIcon {
                try add(Data("fixture-icon".utf8), path: "\(appRoot)/AppIcon60x60@3x.png", to: archive)
            }

            if includeEntitlements {
                let entitlements = try propertyListData([
                    "aps-environment": "development",
                    "com.apple.security.application-groups": ["group.example.demo"]
                ])
                try add(entitlements, path: "\(appRoot)/archived-expanded-entitlements.xcent", to: archive)
            }

            if includeShareExtension {
                let extensionInfo = try propertyListData([
                    "CFBundleDisplayName": "Share",
                    "CFBundleIdentifier": "\(app.bundleIdentifier).share",
                    "CFBundleExecutable": "Share",
                    "NSExtension": [
                        "NSExtensionPointIdentifier": "com.apple.share-services"
                    ]
                ])
                try add(
                    extensionInfo,
                    path: "\(appRoot)/PlugIns/Share.appex/Info.plist",
                    to: archive
                )
                if includeMobileProvision {
                    try add(
                        Self.makeMinimalMobileProvisionData(),
                        path: "\(appRoot)/PlugIns/Share.appex/embedded.mobileprovision",
                        to: archive
                    )
                    try add(
                        Data("share-extension-executable".utf8),
                        path: "\(appRoot)/PlugIns/Share.appex/Share",
                        to: archive
                    )
                }
            }

            if includeMobileProvision {
                try add(
                    Self.makeMinimalMobileProvisionData(),
                    path: "\(appRoot)/embedded.mobileprovision",
                    to: archive
                )
                try add(
                    Data("main-executable".utf8),
                    path: "\(appRoot)/\(app.name)",
                    to: archive
                )
            }
        }

        for entry in extraEntries {
            try add(entry.data, path: entry.path, to: archive)
        }

        return archiveURL
    }

    private static func propertyListData(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .binary,
            options: 0
        )
    }

    private static func add(_ data: Data, path: String, to archive: Archive) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<(start + size))
        }
    }

    /// 供 SignedIPAIdentityReader 测试使用的最小描述文件数据。
    /// 实际内容不追求 Apple 格式完整，只要 ProvisioningProfileReader 能解析出关键字段即可。
    static func makeMinimalMobileProvisionData() -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>UUID</key>
            <string>FIXTURE-PROFILE-UUID</string>
            <key>Name</key>
            <string>Fixture Profile</string>
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
            <array>
                <data>QUFBQQ==</data>
                <data>QkJCQg==</data>
            </array>
        </dict>
        </plist>
        """
        return Data(xml.utf8)
    }

    /// 生成一个带描述文件和可执行文件的 Signed Seal IPA fixture，并返回 AppBundleSigningIdentityReader。
    /// 测试可通过 inspector 闭包控制每个可执行文件的 CMS 读取结果。
    static func signedSeal(
        mainSigner: String,
        extensionSigner: String
    ) throws -> (data: Data, reader: AppBundleSigningIdentityReader) {
        let archiveURL = try make(
            apps: [AppSpec(
                directoryName: "Seal.app",
                bundleIdentifier: "com.example.seal",
                name: "Seal",
                version: "1.0.0",
                buildNumber: "1"
            )],
            includeShareExtension: true,
            includeMobileProvision: true
        )
        let data = try Data(contentsOf: archiveURL)
        let reader = AppBundleSigningIdentityReader { url in
            let serial = url.path.contains("PlugIns") ? extensionSigner : mainSigner
            return ExecutableSignerEvidence(serialNumber: serial, cmsValid: true, codeDirectoryValid: true)
        }
        return (data, reader)
    }
}
