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
}
