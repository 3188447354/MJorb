import Foundation
import Testing
@testable import Seal

/// `profile-only` 准入的设备端身份核验 —— **三态**语义的回归钉。
///
/// 背景（2026-09-25 构建 39 真机）：旧实现把核验写成
/// `await DeviceProfileInspector.containsProfile(...) == true` 后**直接抛
/// `SEAL-PROFILE-362`**，于是「**无法核验**」（`nil`：通道抖动 / 枚举失败 / provider
/// 被并发 reset）与「**身份不符**」（`false`：记录确实过期）折成同一条死路 ⇒
/// 用户点单个应用续签连试三次全部失败，而同一时刻「续签全部」却能过
///（两条路径只差通道时序，记录与证书完全相同）。
///
/// 这里的四条出口必须**分开**：`nil` 绝不能被当成 `false`。
/// 与 `DeviceProfileCleaner` / `InstalledAppDeviceVerifier` 同族 —— 凡是
/// 「问设备 → 按答案做决定」的路径都要保住「无法核验」这一态。
struct ProfileOnlyIdentityVerifierTests {

    @Test
    func confirmedWhenDeviceReportsTheExactIdentity() async {
        let app = makeApp()

        let identity = await ProfileOnlyIdentityVerifier.verify(
            app: app,
            targetBundleIdentifier: "com.example.demo.TEAM123456",
            inspect: { _, _, _ in true }
        )

        #expect(identity == .confirmed)
    }

    @Test
    func mismatchedWhenDeviceEnumeratedButIdentityAbsent() async {
        let app = makeApp()

        let identity = await ProfileOnlyIdentityVerifier.verify(
            app: app,
            targetBundleIdentifier: "com.example.demo.TEAM123456",
            inspect: { _, _, _ in false }
        )

        #expect(identity == .mismatched)
    }

    /// 🔴 本测试是这次修复的**核心回归钉**。
    ///
    /// `nil` = 设备通道或解析不可用 ⇒ **无法核验**。旧实现把它当成「核验失败」并
    /// 终结本轮，导致应用永久续签不了。新行为必须落到 `.unavailable`，
    /// 由调用方**回落完整重签**，而不是抛错。
    @Test
    func unavailableWhenDeviceInspectionIsImpossible() async {
        let app = makeApp()

        let identity = await ProfileOnlyIdentityVerifier.verify(
            app: app,
            targetBundleIdentifier: "com.example.demo.TEAM123456",
            inspect: { _, _, _ in nil }
        )

        #expect(identity == .unavailable)
        // 必须与「身份不符」**可区分** —— 两者的下一步动作相同（都是完整重签），
        // 但排障时要能说出到底是「记录过期」还是「通道没连上」。
        #expect(identity != .mismatched)
    }

    @Test
    func missingRecordedIdentitySkipsDeviceQueryEntirely() async {
        var app = makeApp()
        app.provisioningProfileUUID = nil
        let queried = LockedBox(false)

        let identity = await ProfileOnlyIdentityVerifier.verify(
            app: app,
            targetBundleIdentifier: "com.example.demo.TEAM123456",
            inspect: { _, _, _ in
                queried.set(true)
                return true
            }
        )

        #expect(identity == .missingRecordedIdentity)
        // 记录里就没有可核验的身份 ⇒ 不该白跑一趟设备查询（那会白白等通道）。
        #expect(queried.value == false)
    }

    @Test
    func missingCertificateSerialNumberAlsoFallsBack() async {
        var app = makeApp()
        app.certificateSerialNumber = nil

        let identity = await ProfileOnlyIdentityVerifier.verify(
            app: app,
            targetBundleIdentifier: "com.example.demo.TEAM123456",
            inspect: { _, _, _ in true }
        )

        #expect(identity == .missingRecordedIdentity)
    }

    /// 每种「没确认」的情形都必须有一句能照着排障的原因文案。
    @Test
    func everyUnconfirmedCaseCarriesADiagnosableReason() {
        for identity in [ProfileOnlyIdentity.missingRecordedIdentity, .mismatched, .unavailable] {
            #expect(identity.fallbackReason.isEmpty == false)
        }
        // 三条原因必须互不相同，否则日志里分不出是哪一种。
        let reasons = Set([
            ProfileOnlyIdentity.missingRecordedIdentity.fallbackReason,
            ProfileOnlyIdentity.mismatched.fallbackReason,
            ProfileOnlyIdentity.unavailable.fallbackReason
        ])
        #expect(reasons.count == 3)
    }

    // MARK: - Fixtures

    private func makeApp() -> AppRecord {
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        let mainBundleID = "com.example.demo.TEAM123456"
        return AppRecord(
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: mainBundleID,
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
            provisioningProfileUUID: "MAIN-PROFILE",
            provisioningProfileExpirationDate: expiry,
            signingTargets: [
                SigningTargetRecord(
                    bundleIdentifier: mainBundleID,
                    profileUUID: "MAIN-PROFILE",
                    profileName: nil,
                    profileCreationDate: nil,
                    profileExpirationDate: expiry,
                    teamIdentifier: "TEAM123456",
                    certificateSerialNumbers: ["00AABB"],
                    deviceIdentifiers: ["DEVICE-UDID"],
                    entitlementKeys: []
                )
            ],
            ipaRelativePath: "Apps/Demo.ipa",
            signedIPARelativePath: "Apps/Demo-Signed.ipa",
            signedIPASHA256: "hash",
            signedArtifactStatus: .installed,
            isSeal: false,
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            extensions: []
        )
    }
}

/// 极小的线程安全盒子：`inspect` 闭包是 `async` 且可能跨并发域调用，
/// 用普通 `var` 捕获会触发并发检查（本仓已有同类 helper 的踩坑记录）。
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        storage = newValue
    }
}
