import Foundation

/// 「续签这个已安装应用时该用哪个账号」的**唯一判据**。
///
/// ## 为什么需要它
///
/// 应用记录里的 `accountID` 可能是**悬空引用**：`SettingsViewModel.deleteAccount`
/// 刻意保留应用的账号绑定（原文：「关联应用保留原账号绑定，用于防止误用其他账号续签」），
/// 但删除之后那个 UUID 在账号库里**已经不存在了**。
///
/// 旧实现有三处入口都直接信任这个 UUID：
/// - `AppsViewModel.beginRenewalDirectly`（抽屉 / 详情页的「立即续签」）
/// - `AppsViewModel.beginSigning`（所有续签的汇合点）
/// - `RefreshPlanner.makeQueue`（批量续签）
///
/// ⇒ 后果：「删掉 Apple ID 再重新添加」之后，**除了 Seal 自己**（它靠
/// `SelfAppRegistrar` 从运行包的描述文件回补 Team / 账号）以外的应用**永远无法续签**，
/// 而界面还显示「未记录·自动选择」，**显示与行为正好相反**。
/// 而且 `beginSigning` 里那句 `app.accountID ?? accountID` 的兜底**永远不会执行**
/// —— 悬空 UUID 不是 `nil`，短路了 `??`。这与证书轮换自动恢复里的
/// `candidate.accountID == accountID` 是同一个陷阱的两种表现。
///
/// ## 解析优先级（先安全、后兜底）
///
/// 1. 用户显式指定的账号（`overrideAccountID`）—— 必须可选；
/// 2. 记录里的账号 —— **必须真的存在于账号库**：
///    - 存在且可选 ⇒ 用它；
///    - 存在但不可选（需重新验证）⇒ 如实报 `recordedAccountNeedsVerification`，
///      **不静默换账号**；
/// 3. 与记录里 `signingTeamID` **同 Team** 的可选账号 —— 见下；
/// 4. 有 Team 信息但找不到同 Team 的账号 ⇒ `recordedAccountMissing`，**拒绝**；
/// 5. 记录里没有 Team 信息（旧数据）⇒ 才允许退回传入账号 / 第一个可选账号。
///
/// ## 为什么以 Team 为准
///
/// Seal 签出的 Bundle ID 形如 `<bundle>.<TEAM>`（例如
/// `com.kdt.livecontainer.seal.CT8QZ7352B`）。**同 Team 才是安全回退**：签名身份一致、
/// Keychain 访问组与 App Group 不变。换 Team 会让这些前缀失配
///（Seal 自己在 `beginSigning` 里就有「更新将重置本地数据」的拦截，理由相同）。
/// 所以第 3 步只认同 Team，第 4 步宁可拒绝也不静默换 Team。
///
/// 顺带修掉一个不一致：旧实现里「按 Team 匹配」**只给 `isSeal` 开了口子**
///（`beginRenewalDirectly` 与 `RefreshPlanner` 都是 `if app.isSeal, let teamID = ...`），
/// 而风险与判据对所有应用完全相同 ⇒ 现在统一对所有应用生效。
enum RenewalAccountResolver {

    /// 解析结果。刻意做成三态以上，而不是 `UUID?` ——
    /// 「找不到账号」有好几种**下一步动作完全不同**的原因，折成一个 `nil` 就说不清了。
    enum Resolution: Equatable {
        /// 可以用这个账号续签
        case resolved(UUID)
        /// 记录里的账号还在，但当前不可选（需要重新验证）⇒ 引导去「我的」重新验证
        case recordedAccountNeedsVerification(UUID)
        /// 记录里的账号已不存在，且没有同 Team 的可用账号 ⇒ 不能自动续签
        case recordedAccountMissing(recordedTeamID: String?)
        /// 一个可用账号都没有
        case noSelectableAccount
    }

    static func resolve(
        recordedAccountID: UUID?,
        recordedTeamID: String?,
        accounts: [AppleAccountRecord],
        overrideAccountID: UUID? = nil,
        fallbackAccountID: UUID? = nil
    ) -> Resolution {
        let selectable = accounts.filter { AccountAvailabilityPolicy.isSelectable($0) }
        guard selectable.isEmpty == false else { return .noSelectableAccount }

        // 1. 用户显式指定优先（抽屉里手动选过账号）
        if let overrideAccountID,
           selectable.contains(where: { $0.id == overrideAccountID }) {
            return .resolved(overrideAccountID)
        }

        // 2. 记录里的账号：必须真的存在，不能是悬空引用
        if let recordedAccountID,
           let recorded = accounts.first(where: { $0.id == recordedAccountID }) {
            return AccountAvailabilityPolicy.isSelectable(recorded)
                ? .resolved(recorded.id)
                : .recordedAccountNeedsVerification(recorded.id)
        }

        let team = recordedTeamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTeam = team?.isEmpty == false

        // 3. 同 Team 回退（同 Team ⇒ Bundle ID / Keychain 访问组不变）
        if let team, hasTeam,
           let sameTeam = selectable.first(where: {
               $0.teamID.caseInsensitiveCompare(team) == .orderedSame
           }) {
            return .resolved(sameTeam.id)
        }

        // 4. 有 Team 信息却匹配不上 ⇒ 拒绝，绝不静默换 Team
        if hasTeam {
            return .recordedAccountMissing(recordedTeamID: team)
        }

        // 5. 旧数据没有 Team 信息 ⇒ 只能按传入账号 / 第一个可选账号（与旧行为一致）
        if let fallbackAccountID,
           selectable.contains(where: { $0.id == fallbackAccountID }) {
            return .resolved(fallbackAccountID)
        }
        return .resolved(selectable[0].id)
    }
}
