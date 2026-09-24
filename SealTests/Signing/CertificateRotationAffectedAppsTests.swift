import Foundation
import Testing
@testable import Seal

/// `SigningCoordinator.appsAffectedByCertificateRotation` 的判据测试。
///
/// 这条判据错法的代价是**静默失效**：撤销已经发生、受影响 App 已经打不开，
/// 而恢复流程一声不响地跳过。它不崩、不报错、不红任何既有测试 —— 所以必须在这里钉住。
/// （2026-09-24 连续两轮真机「自动续签 0 个 / 受影响应用 0 个」就是这么来的。）
///
/// 🔴 **核心回归：不得按 `accountID` 过滤。**
/// `SettingsViewModel.deleteAccount` 刻意保留应用的旧 `accountID`
/// （原文：「关联应用保留原账号绑定，用于防止误用其他账号续签」），
/// 而重新添加同一 Apple ID 时 `duplicateAccount == nil` ⇒ 建**新 UUID** ⇒ 恒不相等。
/// 于是「本机无私钥」（要删过账号）与「accountID 相等」（要没删过）**互斥**，
/// 恢复永远不会触发。一旦有人把 `candidate.accountID == accountID` 加回来，
/// 本文件第一条测试就会红。
@Suite("证书轮换：受影响的已安装应用判据")
struct CertificateRotationAffectedAppsTests {
    private let liveAccountID = UUID()
    private let revokedSerial = "00A1B2C3"

    private func makeApp(
        name: String,
        serial: String?,
        accountID: UUID?,
        state: AppState = .installed,
        isSeal: Bool = false,
        targetSerials: [String] = []
    ) -> AppRecord {
        AppRecord(
            originalBundleIdentifier: "com.example.\(name)",
            name: name,
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: state,
            accountID: accountID,
            certificateSerialNumber: serial,
            signingTargets: targetSerials.map { targetSerial in
                SigningTargetRecord(
                    bundleIdentifier: "com.example.\(name).widget",
                    profileUUID: "PROFILE-\(name)",
                    profileName: "Profile \(name)",
                    profileCreationDate: nil,
                    profileExpirationDate: Date(),
                    teamIdentifier: "TEAM123456",
                    certificateSerialNumbers: [targetSerial],
                    deviceIdentifiers: [],
                    entitlementKeys: []
                )
            },
            ipaRelativePath: "Apps/\(name)/Original.ipa",
            isSeal: isSeal,
            importedAt: Date()
        )
    }

    private func affected(
        _ apps: [AppRecord],
        revoked: [String]? = nil,
        excluding: UUID? = nil,
        includeSeal: Bool = true
    ) -> [AppRecord] {
        SigningCoordinator.appsAffectedByCertificateRotation(
            in: apps,
            revokedSerials: revoked ?? [revokedSerial],
            excludingAppID: excluding ?? UUID(),
            includeSeal: includeSeal
        )
    }

    // MARK: - 核心回归：accountID 不参与判据

    /// **这是本轮修复的主断言。**
    ///
    /// 应用的 `accountID` 指向一个**已经不存在**的账号记录（`deleteAccount` 删了记录与
    /// keychain 条目，但刻意保留了应用上的旧绑定）—— 这正是真机上唯一能造出
    /// 「本机无私钥 + 证书被撤销」的形状。判据必须只看证书序列号。
    @Test
    func matchesAppWhoseAccountRecordWasDeleted() {
        let orphaned = makeApp(name: "LiveContainer", serial: revokedSerial, accountID: UUID())

        #expect(affected([orphaned]).map(\.name) == ["LiveContainer"])
    }

    /// 同一批里既有「绑定当前账号」也有「绑定已删账号」的，两个都要恢复 ——
    /// 不能只捞出一半（那会让用户以为「修好了」，而实际只修了部分）。
    @Test
    func matchesBothLiveAndOrphanedBindings() {
        let live = makeApp(name: "AAA", serial: revokedSerial, accountID: liveAccountID)
        let orphaned = makeApp(name: "BBB", serial: revokedSerial, accountID: UUID())

        #expect(affected([live, orphaned]).map(\.name) == ["AAA", "BBB"])
    }

    /// 完全不绑定账号（`accountID == nil`）的也要认出来 —— 判据里没有 accountID 这一维。
    @Test
    func matchesAppWithoutAnyAccountBinding() {
        let unbound = makeApp(name: "CCC", serial: revokedSerial, accountID: nil)

        #expect(affected([unbound]).count == 1)
    }

    // MARK: - 序列号比对

    /// 序列号比对必须**归一化**（大小写 + 前导零），否则同一张证书会被读成两张。
    @Test
    func matchesDespiteSerialFormatting() {
        let lowercasePadded = makeApp(name: "DDD", serial: "000a1b2c3", accountID: liveAccountID)

        #expect(affected([lowercasePadded], revoked: ["A1B2C3"]).count == 1)
    }

    /// 没被撤销的证书（哪怕同账号、同形态）绝不能命中 —— 否则会去重签一堆无关的 App。
    @Test
    func ignoresAppsSignedWithOtherCertificates() {
        let other = makeApp(name: "EEE", serial: "DEADBEEF", accountID: liveAccountID)

        #expect(affected([other]).isEmpty)
    }

    /// 顶层 `certificateSerialNumber` 为空、但**扩展的签名目标**里含被撤销序列号时也要命中。
    /// 只看顶层字段会漏掉「主 App 记录没写序列号、扩展写了」的历史数据。
    @Test
    func matchesThroughExtensionSigningTarget() {
        let extensionOnly = makeApp(
            name: "FFF",
            serial: nil,
            accountID: liveAccountID,
            targetSerials: [revokedSerial]
        )

        #expect(affected([extensionOnly]).count == 1)
    }

    // MARK: - 排除与范围

    /// 触发轮换的那个 App 自己不在恢复列表里（它的签名/安装由主流程负责）。
    @Test
    func excludesTheAppThatTriggeredTheRotation() {
        let trigger = makeApp(name: "GGG", serial: revokedSerial, accountID: liveAccountID)

        #expect(affected([trigger], excluding: trigger.id).isEmpty)
    }

    /// 未安装且不是 Seal 的 App 不参与恢复 —— 它没有设备端实例可重装。
    @Test
    func skipsAppsThatAreNotInstalled() {
        let signedOnly = makeApp(
            name: "HHH",
            serial: revokedSerial,
            accountID: liveAccountID,
            state: .signed
        )

        #expect(affected([signedOnly]).isEmpty)
    }

    /// Seal 自己即使状态不是 `.installed` 也要命中 —— 它的「已安装」由自替换事务表达，
    /// 状态字段在安装期间会被改写。
    @Test
    func sealIsConsideredEvenWhenStateIsNotInstalled() {
        let seal = makeApp(
            name: "Seal",
            serial: revokedSerial,
            accountID: liveAccountID,
            state: .signed,
            isSeal: true
        )

        #expect(affected([seal]).count == 1)
    }

    /// `includeSeal: false` 用于「Seal 自己签名成功后、安装之前」那一刻 ——
    /// 此刻绝不能去动 Seal（它正在被覆盖安装）。**这不是可选的优化，是防死锁。**
    @Test
    func includeSealFalseExcludesSeal() {
        let seal = makeApp(name: "Seal", serial: revokedSerial, accountID: liveAccountID, isSeal: true)
        let other = makeApp(name: "III", serial: revokedSerial, accountID: liveAccountID)

        #expect(affected([seal, other], includeSeal: false).map(\.name) == ["III"])
        #expect(affected([seal, other], includeSeal: true).map(\.name) == ["III", "Seal"])
    }

    // MARK: - 顺序与空集

    /// Seal **必须最后**：它一装就会终止当前进程，排在前面会把剩下的恢复全掐断。
    @Test
    func sealIsAlwaysSortedLast() {
        let seal = makeApp(name: "Seal", serial: revokedSerial, accountID: liveAccountID, isSeal: true)
        let later = makeApp(name: "ZZZ", serial: revokedSerial, accountID: liveAccountID)
        let earlier = makeApp(name: "AAA", serial: revokedSerial, accountID: liveAccountID)

        #expect(affected([later, seal, earlier]).map(\.name) == ["AAA", "ZZZ", "Seal"])
    }

    /// 没有任何撤销 ⇒ 空集（不是「全部」）。空集是「本次不轮换」的唯一表达。
    @Test
    func emptyRevokedSerialsMatchesNothing() {
        let app = makeApp(name: "JJJ", serial: revokedSerial, accountID: liveAccountID)

        #expect(affected([app], revoked: []).isEmpty)
    }
}
