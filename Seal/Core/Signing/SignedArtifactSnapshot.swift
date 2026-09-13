import Foundation

/// 签名产物（signedArtifact）与「设备上正在运行的那份构建」（installedSnapshot）的边界。
///
/// 一条 `AppRecord` 同时承载两件事：刚签出来的包，以及设备上正在跑的那个包。
/// UI 展示的到期日取 `provisioningProfileExpirationDate ?? expiryDate`，
/// 所以只要在签名阶段就把顶层 profile 字段推进到新产物，安装失败（或进程中途被杀）时
/// 界面就会显示一个设备上并不存在的日期 —— 用户以为续签成功，直到应用被吊销才发现（R08）。
///
/// 因此规则是：**顶层 profile 字段只描述设备上正在运行的那份构建**；
/// 产物身份由 `signingTargets` 承载，顶层快照等安装校验通过后再推进。
enum SignedArtifactSnapshot {

    /// 签名完成后的产物状态。
    ///
    /// - 未安装的应用：产物已就绪（`.available`），可以装。
    /// - 已安装的第三方应用：产物**还没装上**，绝不能声称 `.installed`。
    /// - Seal 自身：自更新安装会替换本进程，顶层快照由启动同步从运行中的 Bundle 结算
    ///   （R07 / `SelfAppRegistrar`），装失败时那份乐观值会被推翻，因此沿用 `.installed`。
    static func statusAfterSigning(
        originalState: AppState,
        isSeal: Bool
    ) -> SignedArtifactStatus {
        guard originalState == .installed else { return .available }
        return isSeal ? .installed : .awaitingVerification
    }

    /// 安装校验通过后，才把顶层 profile 身份推进到刚装上的那一份。
    static func advanceInstalled(
        of app: inout AppRecord,
        bundleIdentifier: String,
        expiryDate: Date
    ) {
        if let binding = app.signingTargets.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            app.provisioningProfileUUID = binding.profileUUID
            app.provisioningProfileName = binding.profileName
            app.provisioningProfileCreationDate = binding.profileCreationDate
            app.provisioningProfileExpirationDate = binding.profileExpirationDate
        } else {
            // 主 target 匹配不到时只补有效期：把既有 profile 身份清成 nil 会让 UI
            // 从「有到期日」退化成「无到期日」，比保留旧值更糟。
            app.provisioningProfileExpirationDate = expiryDate
        }
        app.expiryDate = expiryDate
    }
}
