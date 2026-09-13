import Foundation
import Testing
@testable import Seal

/// R08：签名产物（signedArtifact）与「设备上正在运行的那份构建」（installedSnapshot）
/// 必须区分开。UI 展示的到期日取 `provisioningProfileExpirationDate ?? expiryDate`，
/// 一旦签名阶段就推进顶层 profile 字段，安装失败时界面会显示设备上并不存在的日期。
struct SignedArtifactSnapshotTests {

    // MARK: - 签名完成时的产物状态

    /// 已安装的第三方应用重签后，产物**还没装上** —— 不能声称「已安装」。
    /// 否则安装失败或进程被杀时，记录会永久停在假的「已安装」，而设备上跑的仍是旧构建。
    @Test
    func reSigningAnInstalledAppMarksTheArtifactAwaitingVerification() {
        #expect(
            SignedArtifactSnapshot.statusAfterSigning(
                originalState: .installed,
                isSeal: false
            ) == .awaitingVerification
        )
    }

    @Test
    func signingAnUninstalledAppMarksTheArtifactAvailable() {
        #expect(
            SignedArtifactSnapshot.statusAfterSigning(
                originalState: .signed,
                isSeal: false
            ) == .available
        )
    }

    /// Seal 自身是唯一例外：自更新会替换本进程，顶层快照由启动同步从**运行中的 Bundle**
    /// 结算（R07/D 包），装失败时那份乐观值会被推翻，因此沿用 `.installed`。
    @Test
    func selfUpdateKeepsTheInstalledArtifactStatus() {
        #expect(
            SignedArtifactSnapshot.statusAfterSigning(
                originalState: .installed,
                isSeal: true
            ) == .installed
        )
    }

    // MARK: - 安装校验通过后的快照推进

    @Test
    func advancingTheSnapshotTakesTheMainTargetProfile() {
        let expiry = Date(timeIntervalSince1970: 1_780_000_000)
        let creation = Date(timeIntervalSince1970: 1_750_000_000)
        var app = makeApp(
            targets: [
                target(
                    bundleIdentifier: "com.example.app.widget",
                    profileUUID: "EXT-UUID",
                    profileName: "Ext",
                    creation: creation,
                    expiry: expiry
                ),
                target(
                    bundleIdentifier: "com.example.app",
                    profileUUID: "MAIN-UUID",
                    profileName: "Main",
                    creation: creation,
                    expiry: expiry
                )
            ],
            profileUUID: "OLD-UUID"
        )

        SignedArtifactSnapshot.advanceInstalled(
            of: &app,
            bundleIdentifier: "com.example.app",
            expiryDate: expiry
        )

        #expect(app.provisioningProfileUUID == "MAIN-UUID")
        #expect(app.provisioningProfileName == "Main")
        #expect(app.provisioningProfileCreationDate == creation)
        #expect(app.provisioningProfileExpirationDate == expiry)
        #expect(app.expiryDate == expiry)
    }

    /// 主 target 匹配不到时：只按传入到期日补顶层有效期，
    /// **不**把既有 profile 身份清成 nil —— 清掉会让 UI 从「有到期日」退化成「无到期日」。
    @Test
    func advancingTheSnapshotWithoutAMatchingTargetKeepsExistingIdentity() {
        let expiry = Date(timeIntervalSince1970: 1_780_000_000)
        var app = makeApp(targets: [], profileUUID: "OLD-UUID")

        SignedArtifactSnapshot.advanceInstalled(
            of: &app,
            bundleIdentifier: "com.example.app",
            expiryDate: expiry
        )

        #expect(app.provisioningProfileUUID == "OLD-UUID")
        #expect(app.provisioningProfileName == "Old")
        #expect(app.provisioningProfileExpirationDate == expiry)
        #expect(app.expiryDate == expiry)
    }

    // MARK: - 夹具

    private func target(
        bundleIdentifier: String,
        profileUUID: String,
        profileName: String,
        creation: Date,
        expiry: Date
    ) -> SigningTargetRecord {
        SigningTargetRecord(
            bundleIdentifier: bundleIdentifier,
            profileUUID: profileUUID,
            profileName: profileName,
            profileCreationDate: creation,
            profileExpirationDate: expiry,
            teamIdentifier: "TEAM123456",
            certificateSerialNumbers: ["SERIAL1"],
            deviceIdentifiers: ["DEVICE-UDID"],
            entitlementKeys: []
        )
    }

    private func makeApp(
        targets: [SigningTargetRecord],
        profileUUID: String
    ) -> AppRecord {
        AppRecord(
            originalBundleIdentifier: "com.example.app",
            mappedBundleIdentifier: "com.example.app.TEAM123456",
            name: "示例应用",
            version: "1.0",
            buildNumber: "1",
            size: 1024,
            state: .installed,
            provisioningProfileUUID: profileUUID,
            provisioningProfileName: "Old",
            ipaRelativePath: "Apps/Example.ipa",
            signingTargets: targets,
            importedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
