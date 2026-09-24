import Foundation

/// 含扩展 IPA 的描述文件分配策略。
///
/// 免费个人团队的默认策略只为主应用处理 Apple App ID 与 Team profile；扩展仍保留，
/// 但由上游 SideSign 使用主描述文件重签。独立模式仅保留给 Seal 自身的内部签名链路，
/// 普通 IPA 不提供切换入口。
enum AppExtensionProfileStrategy: String, Codable, CaseIterable, Equatable, Sendable {
    case sharedMainProfile
    case independentProfiles

    static func defaultFor(isSeal: Bool) -> Self {
        isSeal ? .independentProfiles : .sharedMainProfile
    }

    func portalMappings(
        from mappings: [String: String],
        originalMainBundleID: String
    ) -> [String: String] {
        switch self {
        case .sharedMainProfile:
            guard let mappedMainBundleID = mappings[originalMainBundleID] else { return [:] }
            return [originalMainBundleID: mappedMainBundleID]
        case .independentProfiles:
            return mappings
        }
    }

    func expectedProfileBundleID(
        for signedBundleID: String,
        mappedMainBundleID: String
    ) -> String {
        switch self {
        case .sharedMainProfile:
            return mappedMainBundleID
        case .independentProfiles:
            return signedBundleID
        }
    }

    /// 共享主描述文件隐含一个前提：**主 App 的能力集 ⊇ 每个保留扩展的能力集**。
    ///
    /// 真机实证（构建 27，`Seal-log(7)(1).txt`）：`LiveProcess` 请求
    /// `com.apple.developer.kernel.increased-memory-limit`，而该能力只声明在扩展上、不在主 App 上
    /// ⇒ 共享模式下门户**只为主 App** 提交能力（`portalMappings` 只有主 App）⇒ 主描述文件不授予它
    /// ⇒ 签后逐 bundle 校验必报 `SEAL-ENTITLEMENT-401`（LiveContainer 连续 5 次签不上）。
    /// ⚠️ 独立模式下不会有这个问题：扩展有自己的 App ID，能力会被提交到它自己那份上。
    /// ⇒ 只要出现这种扩展，就必须回退独立描述文件（否则只能「明确失败」，用户就装不上了）。
    struct SharedProfileBlocker: Equatable, Sendable {
        let extensionBundleID: String
        let entitlements: [String]
    }

    /// 返回第一个「请求了主 App 未声明能力」的扩展；没有则 `nil`。
    ///
    /// 结果**稳定排序**（按扩展 Bundle ID 字典序、能力名排序）—— 否则同一份 IPA 的日志会抖，
    /// 对不上（同 R26 那条「主 App 之外的条目仍要按原序稳定排序」）。
    static func sharedProfileBlocker(
        mainBundleID: String,
        entitlementsByBundleID: [String: Set<String>]
    ) -> SharedProfileBlocker? {
        let mainEntitlements = entitlementsByBundleID[mainBundleID] ?? []
        let blockers = entitlementsByBundleID
            .filter { $0.key != mainBundleID }
            .map { ($0.key, $0.value.subtracting(mainEntitlements).sorted()) }
            .filter { $0.1.isEmpty == false }
            .sorted { $0.0 < $1.0 }
        guard let first = blockers.first else { return nil }
        return SharedProfileBlocker(extensionBundleID: first.0, entitlements: first.1)
    }

    /// 把「想要的策略」解析成「本次真正可用的策略」。
    ///
    /// 只可能把 `.sharedMainProfile` 降级成 `.independentProfiles`，永不反向 ——
    /// 反向（独立→共享）会静默丢扩展能力，正是这条要防的。
    static func resolvedForSigning(
        requested: Self,
        mainBundleID: String,
        entitlementsByBundleID: [String: Set<String>]
    ) -> Self {
        guard requested == .sharedMainProfile else { return requested }
        return sharedProfileBlocker(
            mainBundleID: mainBundleID,
            entitlementsByBundleID: entitlementsByBundleID
        ) == nil ? .sharedMainProfile : .independentProfiles
    }
}
