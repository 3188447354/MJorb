import Foundation
import Testing
@testable import Seal

/// 「续签该用哪个账号」的回归测试。
///
/// **为什么值得单独测**：它不崩、不编译失败，只在真机上让用户彻底用不了 ——
/// 2026-09-24 真机（构建 34）实测：`Seal` / `Guoguo` / `LiveContainer` 三个应用都由
/// 同一个 Apple ID 签过，删掉该 Apple ID 再重新添加之后，**除了 Seal 自己以外全部无法续签**，
/// 界面显示「签名账户：未记录·自动选择」，一点「立即续签」就弹
/// 「Apple ID 不可用 / 请选择一个已验证的 Apple ID 进行续签。」。
///
/// 根因是**三处入口都信任记录里的 `accountID`**，而 `deleteAccount` 刻意保留的那条绑定
/// 在账号删除后已经变成**悬空 UUID**（不是 `nil`，所以连 `??` 兜底都短路了）。
@Suite("续签账号解析：悬空引用与同 Team 回退")
struct RenewalAccountResolverTests {

    private let recordedUUID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let otherUUID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    private let team = "CT8QZ7352B"

    private func account(
        id: UUID,
        teamID: String,
        status: AccountStatus = .verified
    ) -> AppleAccountRecord {
        AppleAccountRecord(
            id: id,
            maskedEmail: "sun***n***@gmail.com",
            accountIdentifier: "sun***n***@gmail.com",
            teamID: teamID,
            teamName: "Wan",
            status: status,
            lastVerifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    // MARK: - 主案：删掉 Apple ID 再重新添加

    /// 🔴 本次 bug 的回归：记录里的 UUID 已经被删除，但设备上还有一个**同 Team**的账号。
    /// 旧实现直接把悬空 UUID 传下去 ⇒ 必然被 `beginSigning` 拒掉。
    @Test
    func resolvesToSameTeamAccountWhenRecordedAccountWasDeleted() {
        let fresh = account(id: otherUUID, teamID: team)
        let resolution = RenewalAccountResolver.resolve(
            recordedAccountID: recordedUUID,   // 已删除，账号库里不存在
            recordedTeamID: team,
            accounts: [fresh]
        )
        #expect(resolution == .resolved(otherUUID))
    }

    /// 这条对**所有**应用生效，不只是 Seal —— 旧实现里「按 Team 匹配」被 `isSeal` 挡住，
    /// 而风险与判据对所有应用完全相同。
    @Test
    func teamFallbackIsNotLimitedToSeal() {
        let fresh = account(id: otherUUID, teamID: team)
        let resolution = RenewalAccountResolver.resolve(
            recordedAccountID: recordedUUID,
            recordedTeamID: team,
            accounts: [fresh]
        )
        guard case .resolved(let id) = resolution else {
            Issue.record("同 Team 回退必须对普通应用也生效，实际得到 \(resolution)")
            return
        }
        #expect(id == otherUUID)
    }

    // MARK: - 记录账号仍然有效时不得改变选择

    @Test
    func keepsTheRecordedAccountWhenItStillExists() {
        let recorded = account(id: recordedUUID, teamID: team)
        let another = account(id: otherUUID, teamID: "OTHER99999")
        let resolution = RenewalAccountResolver.resolve(
            recordedAccountID: recordedUUID,
            recordedTeamID: team,
            accounts: [recorded, another]
        )
        #expect(resolution == .resolved(recordedUUID))
    }

    /// 记录账号还在、只是需要重新验证 ⇒ 如实报出，**不静默换成别的账号**。
    @Test
    func reportsNeedsVerificationInsteadOfSilentlySwitching() {
        let recorded = account(id: recordedUUID, teamID: team, status: .needsVerification)
        let resolution = RenewalAccountResolver.resolve(
            recordedAccountID: recordedUUID,
            recordedTeamID: team,
            accounts: [recorded]
        )
        #expect(resolution == .recordedAccountNeedsVerification(recordedUUID))
    }

    // MARK: - 绝不静默换 Team

    /// 记录账号已删、又没有同 Team 的账号 ⇒ **拒绝**，而不是随便挑一个。
    /// 换 Team 会让 `<bundle>.<TEAM>` 的前缀失配（Keychain 访问组 / App Group），
    /// 这正是 `beginSigning` 里「更新将重置本地数据」要拦的事。
    @Test
    func refusesWhenNoAccountSharesTheRecordedTeam() {
        let stranger = account(id: otherUUID, teamID: "OTHER99999")
        let resolution = RenewalAccountResolver.resolve(
            recordedAccountID: recordedUUID,
            recordedTeamID: team,
            accounts: [stranger]
        )
        #expect(resolution == .recordedAccountMissing(recordedTeamID: team))
    }

    @Test
    func teamComparisonIgnoresCaseAndSurroundingWhitespace() {
        let fresh = account(id: otherUUID, teamID: "ct8qz7352b")
        let resolution = RenewalAccountResolver.resolve(
            recordedAccountID: recordedUUID,
            recordedTeamID: "  \(team)  ",
            accounts: [fresh]
        )
        #expect(resolution == .resolved(otherUUID))
    }

    /// 空白 Team 等于「没有 Team 信息」，不能拿它去匹配。
    @Test
    func blankTeamIsTreatedAsMissingTeam() {
        let stranger = account(id: otherUUID, teamID: "OTHER99999")
        let resolution = RenewalAccountResolver.resolve(
            recordedAccountID: recordedUUID,
            recordedTeamID: "   ",
            accounts: [stranger],
            fallbackAccountID: otherUUID
        )
        #expect(resolution == .resolved(otherUUID))
    }

    // MARK: - 手动选账号必须生效

    /// 🔴 第二个 bug：旧 `beginSigning` 用 `app.accountID ?? accountID`，
    /// 悬空 UUID 非 nil ⇒ **用户在抽屉里手动选的账号被无声忽略**。
    @Test
    func explicitOverrideWinsOverDanglingRecordedAccount() {
        let chosen = account(id: otherUUID, teamID: "OTHER99999")
        let resolution = RenewalAccountResolver.resolve(
            recordedAccountID: recordedUUID,
            recordedTeamID: team,
            accounts: [chosen],
            overrideAccountID: otherUUID
        )
        #expect(resolution == .resolved(otherUUID))
    }

    /// 显式指定但那个账号不可选 ⇒ 不采用，继续往下解析。
    @Test
    func unusableOverrideIsIgnored() {
        let unverified = account(id: otherUUID, teamID: team, status: .needsVerification)
        let recorded = account(id: recordedUUID, teamID: team)
        let resolution = RenewalAccountResolver.resolve(
            recordedAccountID: recordedUUID,
            recordedTeamID: team,
            accounts: [unverified, recorded],
            overrideAccountID: otherUUID
        )
        #expect(resolution == .resolved(recordedUUID))
    }

    // MARK: - 旧数据（没有 Team 信息）

    /// 历史记录里没有 Team 时只能退回传入账号 —— 与旧行为一致，不是新引入的宽松。
    @Test
    func fallsBackToProvidedAccountWhenTeamIsUnknown() {
        let fresh = account(id: otherUUID, teamID: "OTHER99999")
        let resolution = RenewalAccountResolver.resolve(
            recordedAccountID: recordedUUID,
            recordedTeamID: nil,
            accounts: [fresh],
            fallbackAccountID: otherUUID
        )
        #expect(resolution == .resolved(otherUUID))
    }

    @Test
    func fallsBackToFirstSelectableWhenTeamAndFallbackAreUnknown() {
        let fresh = account(id: otherUUID, teamID: "OTHER99999")
        let resolution = RenewalAccountResolver.resolve(
            recordedAccountID: recordedUUID,
            recordedTeamID: nil,
            accounts: [fresh],
            fallbackAccountID: nil
        )
        #expect(resolution == .resolved(otherUUID))
    }

    // MARK: - 一个可用账号都没有

    @Test
    func reportsNoSelectableAccountWhenAccountListIsEmpty() {
        let resolution = RenewalAccountResolver.resolve(
            recordedAccountID: recordedUUID,
            recordedTeamID: team,
            accounts: []
        )
        #expect(resolution == .noSelectableAccount)
    }

    @Test
    func reportsNoSelectableAccountWhenEveryAccountNeedsVerification() {
        let only = account(id: otherUUID, teamID: team, status: .needsVerification)
        let resolution = RenewalAccountResolver.resolve(
            recordedAccountID: recordedUUID,
            recordedTeamID: team,
            accounts: [only]
        )
        #expect(resolution == .noSelectableAccount)
    }

    /// `availableOffline` 也算可选（旧构建把临时网络失败存成了 `needsVerification`，
    /// `AccountAvailabilityPolicy.repairedStatus` 会修成这一档）。
    @Test
    func availableOfflineAccountsStaySelectable() {
        let offline = account(id: otherUUID, teamID: team, status: .availableOffline)
        let resolution = RenewalAccountResolver.resolve(
            recordedAccountID: recordedUUID,
            recordedTeamID: team,
            accounts: [offline]
        )
        #expect(resolution == .resolved(otherUUID))
    }

    /// 多个同 Team 账号时结果必须确定（取列表里的第一个），不能随调用顺序抖动。
    @Test
    func sameTeamFallbackIsDeterministic() {
        let first = account(id: recordedUUID, teamID: team)
        let second = account(id: otherUUID, teamID: team)
        let resolution = RenewalAccountResolver.resolve(
            recordedAccountID: UUID(),   // 悬空
            recordedTeamID: team,
            accounts: [first, second]
        )
        #expect(resolution == .resolved(recordedUUID))
    }
}
