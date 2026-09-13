import Foundation
import Testing
@testable import Seal

/// 安装前三入口共用校验。
///
/// 核心要防的是：**主 profile 有效、扩展 profile 已经过期或不含本设备**的包一路走到设备端，
/// 只换来一个 `ApplicationVerificationFailed` 之类的模糊错误。这类包必须在本机就被拦下，
/// 并且说清楚是哪个 target 出的问题。
struct PreInstallValidationTests {
    private let device = "00008120-000A1B2C3D4E5F6G"
    private let team = "TEAM123456"
    private let serial = "ABC123"
    private let mainBundleID = "com.example.app"

    // MARK: - 正常路径

    @Test
    func acceptsWhenEveryTargetIsValid() {
        let app = makeApp(targets: [
            target(mainBundleID),
            target("com.example.app.widget"),
        ])

        #expect(validate(app) == .ok)
    }

    // MARK: - 扩展 target 的独立有效性（本组用例的核心）

    /// 主程序有效、扩展过期 —— 旧实现只查主 target，会放行。
    @Test
    func rejectsWhenExtensionProfileIsExpired() {
        let app = makeApp(targets: [
            target(mainBundleID),
            target("com.example.app.widget", expiry: Date().addingTimeInterval(-60)),
        ])

        guard case let .rejected(failure) = validate(app) else {
            Issue.record("扩展过期必须被拒绝")
            return
        }
        #expect(failure.code == "SEAL-INSTALL-713")
        #expect(failure.reason.contains("扩展"))
        #expect(failure.reason.contains("com.example.app.widget"))
    }

    @Test
    func rejectsWhenExtensionDoesNotContainCurrentDevice() {
        let app = makeApp(targets: [
            target(mainBundleID),
            target("com.example.app.widget", devices: ["SOMEONE-ELSE"]),
        ])

        guard case let .rejected(failure) = validate(app) else {
            Issue.record("扩展不含本设备必须被拒绝")
            return
        }
        #expect(failure.code == "SEAL-INSTALL-714")
        #expect(failure.reason.contains("扩展"))
    }

    @Test
    func rejectsWhenExtensionTeamMismatches() {
        let app = makeApp(targets: [
            target(mainBundleID),
            target("com.example.app.widget", team: "OTHER999"),
        ])

        guard case let .rejected(failure) = validate(app) else {
            Issue.record("扩展 Team 不一致必须被拒绝")
            return
        }
        #expect(failure.code == "SEAL-INSTALL-717")
    }

    @Test
    func rejectsWhenExtensionProfileLacksTheSigningCertificate() {
        let app = makeApp(targets: [
            target(mainBundleID),
            target("com.example.app.widget", serials: ["DEADBEEF"]),
        ])

        guard case let .rejected(failure) = validate(app) else {
            Issue.record("扩展不含本次证书必须被拒绝")
            return
        }
        #expect(failure.code == "SEAL-INSTALL-718")
    }

    // MARK: - 序列号必须归一化

    /// 跨来源比对要归一化（去前导零）。直接字符串比对会把同一张证书判成「已被轮换」。
    @Test
    func normalizesCertificateSerialNumberAcrossSources() {
        let app = makeApp(targets: [target(mainBundleID, serials: ["0ABC123"])])

        // 记录里是 ABC123，描述文件里是 0ABC123 —— 同一张证书
        #expect(validate(app) == .ok)
    }

    // MARK: - 老记录兜底

    /// 升级前签好的包没有 target 明细，只能按设备标识兜底核对 —— 不能直接判死。
    @Test
    func legacyRecordWithoutTargetsFallsBackToDeviceIdentifier() {
        let matching = makeApp(targets: [], signedDeviceIdentifier: device)
        #expect(validate(matching) == .ok)

        let mismatching = makeApp(targets: [], signedDeviceIdentifier: "OTHER-DEVICE")
        guard case let .rejected(failure) = validate(mismatching) else {
            Issue.record("设备不匹配必须被拒绝")
            return
        }
        #expect(failure.code == "SEAL-INSTALL-714a")

        // 连设备标识都没有 = 关键元数据缺失，要求重签而不是放行
        let empty = makeApp(targets: [], signedDeviceIdentifier: nil)
        guard case let .rejected(failure) = validate(empty) else {
            Issue.record("缺关键元数据必须被拒绝")
            return
        }
        #expect(failure.code == "SEAL-INSTALL-721")
    }

    // MARK: - 记录错配与格式

    @Test
    func rejectsWhenMainTargetIsMissingFromRecords() {
        let app = makeApp(targets: [target("com.example.other")])

        guard case let .rejected(failure) = validate(app) else {
            Issue.record("主 target 记录缺失必须被拒绝")
            return
        }
        #expect(failure.code == "SEAL-INSTALL-722")
    }

    @Test
    func rejectsInvalidBundleIdentifier() {
        let app = makeApp(targets: [target("com.example.app")])

        guard case let .rejected(failure) = validate(app, bundleIdentifier: "") else {
            Issue.record("空 Bundle ID 必须被拒绝")
            return
        }
        #expect(failure.code == "SEAL-INSTALL-716")
    }

    /// 不传账号 Team / 证书时跳过这两项核对，但过期与设备仍必须查。
    @Test
    func skipsTeamAndCertificateChecksWhenNotProvided() {
        let app = makeApp(targets: [target(mainBundleID, team: "ANY", serials: ["ANY"])])
        let outcome = PreInstallValidation.validate(
            app: app,
            bundleIdentifier: mainBundleID,
            deviceIdentifier: device,
            accountTeamID: nil,
            certificateSerialNumber: nil
        )
        #expect(outcome == .ok)
    }

    // MARK: - 状态映射

    /// 装不上的原因不同，用户该做的事也不同，列表页状态必须分开。
    @Test
    func mapsRejectionCodesToDistinctArtifactStatuses() {
        #expect(PreInstallValidation.artifactStatus(forCode: "SEAL-INSTALL-713") == .expired)
        #expect(PreInstallValidation.artifactStatus(forCode: "SEAL-INSTALL-714") == .deviceUnavailable)
        #expect(PreInstallValidation.artifactStatus(forCode: "SEAL-INSTALL-714a") == .deviceUnavailable)
        #expect(PreInstallValidation.artifactStatus(forCode: "SEAL-INSTALL-718") == .damaged)
    }

    // MARK: - 夹具

    private func validate(
        _ app: AppRecord,
        bundleIdentifier: String? = nil
    ) -> PreInstallValidation.Outcome {
        PreInstallValidation.validate(
            app: app,
            bundleIdentifier: bundleIdentifier ?? mainBundleID,
            deviceIdentifier: device,
            accountTeamID: team,
            certificateSerialNumber: serial
        )
    }

    private func target(
        _ bundleID: String,
        expiry: Date = Date().addingTimeInterval(6 * 86_400),
        team: String? = nil,
        serials: [String]? = nil,
        devices: [String]? = nil
    ) -> SigningTargetRecord {
        SigningTargetRecord(
            bundleIdentifier: bundleID,
            profileUUID: UUID().uuidString,
            profileName: "Profile",
            profileCreationDate: Date(),
            profileExpirationDate: expiry,
            teamIdentifier: team ?? self.team,
            certificateSerialNumbers: serials ?? [serial],
            deviceIdentifiers: devices ?? [device],
            entitlementKeys: []
        )
    }

    private func makeApp(
        targets: [SigningTargetRecord],
        signedDeviceIdentifier: String? = nil
    ) -> AppRecord {
        AppRecord(
            originalBundleIdentifier: mainBundleID,
            mappedBundleIdentifier: mainBundleID,
            name: "Example",
            version: "1",
            buildNumber: "1",
            size: 1,
            state: .signed,
            accountID: UUID(),
            signingTeamID: team,
            certificateSerialNumber: serial,
            signedDeviceIdentifier: signedDeviceIdentifier,
            provisioningProfileExpirationDate: Date().addingTimeInterval(6 * 86_400),
            signingTargets: targets,
            ipaRelativePath: "Apps/\(UUID().uuidString)/Original.ipa",
            importedAt: Date()
        )
    }
}
