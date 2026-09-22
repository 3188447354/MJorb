import Foundation

/// 早期自管理 Seal 迁移识别策略。本枚举仅在需要兼容旧自安装识别时启用。
/// `isSealIPAPackage`/`isMigrationPackage` 用于识别历史包；`recommendedBundleIdentifier(teamID:)`
/// 返回的 `com.mjorb.seal.t<teamID>`/`.self` 是早期迁移旧格式，当前正式签名统一走
/// `BundleIDPolicy.recommendedBundleIdentifier(_:teamID:)` 的 `.seal.<teamID>` 格式，二者不要混用。
enum SelfManagedSealMigrationPolicy {
    static let canonicalBundleIdentifier = "com.mjorb.seal"

    static func isSealIPAPackage(name: String, bundleIdentifier: String) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedName == "seal"
            || bundleIdentifier == canonicalBundleIdentifier
            || bundleIdentifier.hasPrefix(canonicalBundleIdentifier + ".")
    }

    static func isMigrationPackage(_ app: AppRecord) -> Bool {
        app.isSeal == false
            && app.state != .installed
            && isSealIPAPackage(name: app.name, bundleIdentifier: app.originalBundleIdentifier)
    }

    static func recommendedBundleIdentifier(teamID: String?) -> String {
        let suffix = (teamID ?? "")
            .lowercased()
            .filter { character in
                character.isLetter || character.isNumber
            }

        if suffix.isEmpty {
            return canonicalBundleIdentifier + ".self"
        }
        return canonicalBundleIdentifier + ".t" + String(suffix)
    }
}
