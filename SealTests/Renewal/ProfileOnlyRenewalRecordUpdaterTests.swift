import Foundation
import Testing
@testable import Seal

struct ProfileOnlyRenewalRecordUpdaterTests {

    @Test
    func confirmedProfilesAdvanceMainAndExtensionSnapshotsTogether() throws {
        let oldExpiry = Date(timeIntervalSince1970: 1_800_000_000)
        let newExpiry = Date(timeIntervalSince1970: 1_900_000_000)
        var app = makeApp(expiry: oldExpiry)
        let main = binding(
            bundleIdentifier: "com.example.demo.TEAM123456",
            profileUUID: "NEW-MAIN",
            expiry: newExpiry
        )
        let extensionBinding = binding(
            bundleIdentifier: "com.example.demo.TEAM123456.share",
            profileUUID: "NEW-EXTENSION",
            expiry: newExpiry
        )

        try ProfileOnlyRenewalRecordUpdater.apply(
            resolvedBindings: [
                main.bundleIdentifier: main,
                extensionBinding.bundleIdentifier: extensionBinding
            ],
            teamID: "TEAM123456",
            certificateSerialNumber: "00AABB",
            deviceIdentifier: "DEVICE-UDID",
            to: &app
        )

        // ── 第一阶段：只写草稿，顶层一律不动 ──
        // 顶层描述的是「设备上已确认的那份构建」，界面读的就是顶层（守卫 E 包）。
        // 续签阶段就把顶层推进到新 profile，安装失败时界面会显示一个设备上并不存在的
        // 有效期（用户以为续签成功，直到被吊销都收不到提醒）⇒ 现在只写 pending。
        #expect(app.provisioningProfileUUID == "OLD-MAIN", "转正前顶层不得被推进")
        #expect(app.provisioningProfileExpirationDate == oldExpiry)
        #expect(app.expiryDate == oldExpiry)

        let pending = try #require(app.pendingSignedSnapshot)
        #expect(pending.provisioningProfileUUID == "NEW-MAIN")
        #expect(pending.provisioningProfileExpirationDate == newExpiry)
        #expect(pending.expiryDate == newExpiry)
        #expect(pending.signingTargets.compactMap(\.profileUUID).sorted() == ["NEW-EXTENSION", "NEW-MAIN"])
        #expect(pending.extensionSnapshots.first?.provisioningProfileUUID == "NEW-EXTENSION")
        #expect(pending.extensionSnapshots.first?.provisioningProfileExpirationDate == newExpiry)

        // ── 第二阶段：设备端逐份读回确认后由调用方转正 ──
        // （生产上的调用点在 `SigningCoordinator.renewProfilesOnly`，紧跟在注入成功之后。）
        app.commitPendingSnapshot()

        #expect(app.provisioningProfileUUID == "NEW-MAIN")
        #expect(app.provisioningProfileExpirationDate == newExpiry)
        #expect(app.expiryDate == newExpiry)
        #expect(app.signingTargets.compactMap(\.profileUUID).sorted() == ["NEW-EXTENSION", "NEW-MAIN"])
        #expect(app.extensions.first?.provisioningProfileUUID == "NEW-EXTENSION")
        #expect(app.pendingSignedSnapshot == nil, "转正后草稿必须清空")
        #expect(app.signedArtifactStatus == .installed)
    }

    @Test
    func sharedMainProfileIsRecordedForEveryTargetWithoutCollapsingThem() throws {
        let newExpiry = Date(timeIntervalSince1970: 1_900_000_000)
        var app = makeApp(expiry: Date(timeIntervalSince1970: 1_800_000_000))
        // 共享主描述文件：门户只取回**主 App 那一份**，扩展嵌入的就是它
        // ⇒ 两个目标解析到**同一个** binding（这正是 `resolvedBindings` 的语义）。
        let shared = binding(
            bundleIdentifier: "com.example.demo.TEAM123456",
            profileUUID: "NEW-MAIN",
            expiry: newExpiry
        )
        let mainBundleIdentifier = "com.example.demo.TEAM123456"
        let extensionBundleIdentifier = "com.example.demo.TEAM123456.share"

        try ProfileOnlyRenewalRecordUpdater.apply(
            resolvedBindings: [
                mainBundleIdentifier: shared,
                extensionBundleIdentifier: shared
            ],
            teamID: "TEAM123456",
            certificateSerialNumber: "00AABB",
            deviceIdentifier: "DEVICE-UDID",
            to: &app
        )

        // 关键不变量（R65⑩）：记录**不能塌成一条**。若沿用 `SigningTargetRecord(binding:)`
        // （它拿 **profile 内**的 bundleIdentifier 当键），两条记录会都变成主 App
        // ⇒ 缓存与安装前校验逐项匹配失配 ✗。
        let pending = try #require(app.pendingSignedSnapshot)
        #expect(pending.signingTargets.count == 2)
        #expect(
            pending.signingTargets.map(\.bundleIdentifier).sorted()
                == [mainBundleIdentifier, extensionBundleIdentifier].sorted()
        )
        // 扩展记录的描述文件身份必须是**共享的那一份**（而不是「缺失」）。
        #expect(pending.extensionSnapshots.first?.provisioningProfileUUID == "NEW-MAIN")
        #expect(pending.extensionSnapshots.first?.provisioningProfileExpirationDate == newExpiry)

        // 转正之后同样不能塌：两条目标、扩展指向共享的那一份主描述文件。
        app.commitPendingSnapshot()
        #expect(app.signingTargets.count == 2)
        #expect(
            app.signingTargets.map(\.bundleIdentifier).sorted()
                == [mainBundleIdentifier, extensionBundleIdentifier].sorted()
        )
        #expect(app.extensions.first?.provisioningProfileUUID == "NEW-MAIN")
        #expect(app.extensions.first?.provisioningProfileExpirationDate == newExpiry)
    }

    private func makeApp(expiry: Date) -> AppRecord {
        AppRecord(
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: "com.example.demo.TEAM123456",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            expiryDate: expiry,
            accountID: UUID(),
            signingTeamID: "TEAM123456",
            certificateSerialNumber: "00AABB",
            signedDeviceIdentifier: "DEVICE-UDID",
            provisioningProfileUUID: "OLD-MAIN",
            provisioningProfileExpirationDate: expiry,
            signingTargets: [],
            ipaRelativePath: "Apps/Demo.ipa",
            signedIPARelativePath: "Apps/Demo-Signed.ipa",
            signedIPASHA256: "hash",
            signedArtifactStatus: .installed,
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            extensions: [
                AppExtensionRecord(
                    name: "Share",
                    originalBundleIdentifier: "com.example.demo.share",
                    mappedBundleIdentifier: "com.example.demo.TEAM123456.share",
                    kind: .share,
                    provisioningProfileUUID: "OLD-EXTENSION",
                    provisioningProfileExpirationDate: expiry,
                    certificateSerialNumber: "00AABB"
                )
            ]
        )
    }

    private func binding(
        bundleIdentifier: String,
        profileUUID: String,
        expiry: Date
    ) -> ProvisioningProfileBinding {
        ProvisioningProfileBinding(
            bundleIdentifier: bundleIdentifier,
            profileUUID: profileUUID,
            profileName: "Profile \(profileUUID)",
            teamIdentifier: "TEAM123456",
            creationDate: Date(timeIntervalSince1970: 1_850_000_000),
            expirationDate: expiry,
            certificateSerialNumbers: ["00AABB"],
            deviceIdentifiers: ["DEVICE-UDID"],
            entitlements: [:]
        )
    }
}
