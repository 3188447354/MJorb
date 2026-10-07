import Foundation

/// 版本比较结果：用于导入时判断是升级、同版本还是降级
enum VersionCheckResult: Equatable, Sendable {
    /// 新记录，没有已存在的同 Bundle ID 记录
    case newApp
    /// 高版本：正常升级，直接覆盖
    case upgrade(oldVersion: String, newVersion: String)
    /// 同版本同内容：已是最新，阻止导入
    case alreadyLatest(version: String)
    /// 同版本不同内容：需要用户确认
    case sameVersionDifferentContent(version: String)
    /// 低版本：降级警告，需要用户二次确认
    case downgrade(oldVersion: String, newVersion: String)
    /// 同营销版本但构建号更高：视为升级（例如 v1.0.0 build 68 → build 69）
    case buildUpgrade(oldBuild: String, newBuild: String, version: String)
    /// 同营销版本但构建号更低：视为降级
    case buildDowngrade(oldBuild: String, newBuild: String, version: String)
}

struct ImportDraft: Equatable, Identifiable, Sendable {
    let appID: UUID
    let parsedIPA: ParsedIPA
    let stagedIPA: StagedIPA
    /// 版本检查结果（prepare 阶段计算，UI 用来决定是否弹框）
    let versionCheck: VersionCheckResult

    var id: UUID { appID }
}
