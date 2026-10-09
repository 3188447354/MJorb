import Foundation
import Testing
@testable import Seal

struct AppRecordTests {
    @Test
    func importedRecordPreservesParsedMetadata() {
        let appID = UUID()
        let extensionID = UUID()
        let importedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let appExtension = AppExtensionRecord(
            id: extensionID,
            name: "Share",
            originalBundleIdentifier: "com.example.demo.share",
            kind: .share
        )

        let record = AppRecord(
            id: appID,
            originalBundleIdentifier: "com.example.demo",
            name: "Demo",
            version: "1.2.3",
            buildNumber: "45",
            size: 12_345,
            state: .imported,
            ipaRelativePath: "Apps/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/Original.ipa",
            importedAt: importedAt,
            extensions: [appExtension]
        )

        #expect(record.id == appID)
        #expect(record.originalBundleIdentifier == "com.example.demo")
        #expect(record.name == "Demo")
        #expect(record.version == "1.2.3")
        #expect(record.buildNumber == "45")
        #expect(record.size == 12_345)
        #expect(record.state == .imported)
        #expect(record.importedAt == importedAt)
        #expect(record.extensions == [appExtension])
        #expect(record.isSeal == false)
        #expect(record.isPinned == false)
    }


    @Test
    func signedButNotInstalledRecordLocksSigningIdentity() {
        let expiration = Date(timeIntervalSinceNow: 86_400)
        let record = AppRecord(
            originalBundleIdentifier: "com.example.original",
            mappedBundleIdentifier: "com.example.signed",
            name: "Pending Install",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .failedRecoverable,
            accountID: UUID(),
            signingTeamID: "TEAM123",
            certificateSerialNumber: "ABCDEF123456",
            signedDeviceIdentifier: "UDID-123",
            provisioningProfileExpirationDate: expiration,
            ipaRelativePath: "Apps/pending/Original.ipa",
            signedIPARelativePath: "Apps/pending/Signed.ipa",
            importedAt: Date()
        )

        #expect(record.hasPersistedSigningIdentity)
        #expect(record.requiresLockedSigningIdentity)
    }

    @Test
    func previouslyInstalledRecordStaysInInstalledListDuringRenewal() {
        let record = AppRecord(
            originalBundleIdentifier: "com.example.installed",
            mappedBundleIdentifier: "com.example.installed.seal",
            name: "Installed",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .signing,
            lastInstalledAt: Date(timeIntervalSince1970: 1_800_000_000),
            ipaRelativePath: "Apps/installed/Original.ipa",
            signedIPARelativePath: "Apps/installed/Signed.ipa",
            signedIPASHA256: String(repeating: "a", count: 64),
            signedArtifactStatus: .installFailed,
            importedAt: Date()
        )

        #expect(record.belongsInInstalledList)
        #expect(record.belongsInSignedList == false)
        #expect(record.belongsInUnsignedList == false)
    }

    @Test
    func signedButNeverInstalledRemainsInPendingListUntilInstalled() {
        let record = AppRecord(
            originalBundleIdentifier: "com.example.pending",
            mappedBundleIdentifier: "com.example.pending.seal",
            name: "Pending",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .signed,
            ipaRelativePath: "Apps/pending/Original.ipa",
            signedIPARelativePath: "Apps/pending/Signed.ipa",
            signedIPASHA256: String(repeating: "b", count: 64),
            signedArtifactStatus: .available,
            importedAt: Date()
        )

        #expect(record.belongsInInstalledList == false)
        // 两列表设计：已签但未安装、非 Seal 的副本仍归待处理（unsigned）列表，直到真正安装；
        // 不存在独立的 signed 列表（belongsInSignedList 恒 false）
        #expect(record.belongsInSignedList == false)
        #expect(record.belongsInUnsignedList)
    }

    @Test
    func importedRecordOnlyAppearsInUnsignedList() {
        let record = AppRecord(
            originalBundleIdentifier: "com.example.imported",
            name: "Imported",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .imported,
            ipaRelativePath: "Apps/imported/Original.ipa",
            importedAt: Date()
        )

        #expect(record.belongsInInstalledList == false)
        #expect(record.belongsInSignedList == false)
        #expect(record.belongsInUnsignedList)
    }

    @Test
    func userIdentityKeysNormalizeBundleIdentifiersForDuplicateSuppression() {
        let record = AppRecord(
            originalBundleIdentifier: " COM.EXAMPLE.APP ",
            mappedBundleIdentifier: "com.example.app.seal.TEAM",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            ipaRelativePath: "Apps/demo/Original.ipa",
            preferredBundleIdentifier: "com.example.app",
            importedAt: Date()
        )

        #expect(record.userIdentityKeys.contains("com.example.app"))
        #expect(record.userIdentityKeys.contains("com.example.app.seal.team"))
        #expect(record.userIdentityKeys.count == 2)
    }

    @Test(arguments: [
        (AppState.imported, "imported"),
        (AppState.preflightPassed, "preflightPassed"),
        (AppState.signed, "signed"),
        (AppState.installed, "installed"),
        (AppState.failedRecoverable, "failedRecoverable"),
        (AppState.failedFinal, "failedFinal")
    ])
    func appStateHasStablePersistenceValue(state: AppState, rawValue: String) {
        #expect(state.rawValue == rawValue)
        #expect(AppState(rawValue: rawValue) == state)
    }

    @Test
    func importFailureContainsOneRecoveryAction() {
        let failure = ImportFailure(
            title: "无法读取 IPA",
            reason: "未找到应用信息",
            recovery: "选择其他 IPA",
            code: "SEAL-IPA-101"
        )

        #expect(failure.title == "无法读取 IPA")
        #expect(failure.reason == "未找到应用信息")
        #expect(failure.recovery == "选择其他 IPA")
        #expect(failure.code == "SEAL-IPA-101")
    }

    // MARK: - 2026-10-09 覆盖更新重设计：列表互斥性

    @Test
    func pendingSealUpdateBelongsInUnsignedList() {
        // Seal 待签名更新包：不进已安装，只进待签名
        let oldID = UUID()
        let record = AppRecord(
            originalBundleIdentifier: "com.seal.app",
            name: "Seal",
            version: "1.0.0",
            buildNumber: "131",
            size: 10_000,
            state: .imported,
            ipaRelativePath: "Apps/NEW/Original.ipa",
            isSeal: true,
            importedAt: Date(),
            replacesInstalledAppID: oldID
        )
        #expect(record.belongsInInstalledList == false)
        #expect(record.belongsInUnsignedList == true)
    }

    @Test
    func installedSealBelongsInInstalledList() {
        // 正常已安装 Seal：进已安装，不进待签名
        let record = AppRecord(
            originalBundleIdentifier: "com.seal.app",
            name: "Seal",
            version: "1.0.0",
            buildNumber: "130",
            size: 10_000,
            state: .installed,
            ipaRelativePath: "Apps/OLD/Original.ipa",
            isSeal: true,
            importedAt: Date(),
            replacesInstalledAppID: nil
        )
        #expect(record.belongsInInstalledList == true)
        #expect(record.belongsInUnsignedList == false)
    }

    @Test
    func pendingNonSealUpdateBelongsInUnsignedList() {
        // 非 Seal 待签名更新包：不进已安装，只进待签名
        let oldID = UUID()
        let record = AppRecord(
            originalBundleIdentifier: "com.example.app",
            name: "Demo",
            version: "2.0",
            buildNumber: "20",
            size: 10_000,
            state: .imported,
            ipaRelativePath: "Apps/NEW/Original.ipa",
            isSeal: false,
            importedAt: Date(),
            replacesInstalledAppID: oldID
        )
        #expect(record.belongsInInstalledList == false)
        #expect(record.belongsInUnsignedList == true)
    }

    @Test
    func missingOnDeviceMovesRecordOutOfInstalledListWithoutDiscardingSignedArtifact() {
        var record = AppRecord(
            originalBundleIdentifier: "com.example.installed",
            mappedBundleIdentifier: "com.example.installed.seal",
            name: "Installed",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            lastInstalledAt: Date(),
            ipaRelativePath: "Apps/installed/Original.ipa",
            signedIPARelativePath: "Apps/installed/Signed.ipa",
            signedIPASHA256: String(repeating: "a", count: 64),
            signedArtifactStatus: .installed,
            importedAt: Date()
        )

        record.markMissingOnDevice()

        #expect(record.belongsInInstalledList == false)
        #expect(record.belongsInUnsignedList == true)
        #expect(record.state == .signed)
        #expect(record.lastInstalledAt == nil)
        #expect(record.signedIPARelativePath == "Apps/installed/Signed.ipa")
        #expect(record.signedIPASHA256 == String(repeating: "a", count: 64))
        #expect(record.signedArtifactStatus == .available)
    }

    @Test
    func clearingSignedArtifactKeepsInstalledRecordAndOriginalIPA() {
        var record = AppRecord(
            originalBundleIdentifier: "com.example.installed",
            mappedBundleIdentifier: "com.example.installed.seal",
            name: "Installed",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            lastInstalledAt: Date(),
            ipaRelativePath: "Apps/installed/Original.ipa",
            signedIPARelativePath: "Apps/installed/Signed.ipa",
            signedIPASHA256: String(repeating: "a", count: 64),
            signedIPAFileSize: 4_096,
            signedIPAModificationDate: Date(),
            signedArtifactStatus: .installed,
            importedAt: Date()
        )

        record.clearSignedArtifact()

        #expect(record.ipaRelativePath == "Apps/installed/Original.ipa")
        #expect(record.belongsInInstalledList)
        #expect(record.signedIPARelativePath == nil)
        #expect(record.signedIPASHA256 == nil)
        #expect(record.signedIPAFileSize == nil)
        #expect(record.signedIPAModificationDate == nil)
        #expect(record.signedArtifactStatus == .missing)
    }
}
