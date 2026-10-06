import Foundation

/// 签名产物（signedArtifact）与「设备上正在运行的那份构建」（installedSnapshot）的边界。
///
/// 两阶段提交不变量：**顶层 profile 字段只描述已确认的设备现实**；签名/续签阶段
/// 的新值先写 `pendingSignedSnapshot` 草稿，安装校验通过（或设备端读回确认）后
/// 整体转正。UI 只读顶层，永远不会看到未确认的值。
/// （旧模型是"签名阶段乐观推进顶层，失败再纠正"，已于 2026-10-07 重构废除。）
enum SignedArtifactSnapshot {

    /// 签名完成后的产物状态。
    ///
    /// - 未安装的应用：产物已就绪（`.available`），可以装。
    /// - 已安装的应用：统一 `.awaitingVerification`，由安装校验或启动结算推进到 `.installed`。
    ///   （旧逻辑曾给 Seal 返回 `.installed`，那是乐观写，已废除。）
    /// - 注意：生产代码已改走 `RenewalPolicy.statusAfterSigning`，此 static 仅单测引用。
    static func statusAfterSigning(
        originalState: AppState,
        isSeal: Bool
    ) -> SignedArtifactStatus {
        guard originalState == .installed else { return .available }
        return isSeal ? .installed : .awaitingVerification
    }

    /// 安装校验通过后，才把顶层 profile 身份推进到刚装上的那一份。
    ///
    /// 两阶段提交：从 `pendingSignedSnapshot` 草稿整体转正。
    /// 无 pending 时走回填兜底——正常可达路径：缓存重装（`installCachedSignedIPAIfPossible`）
    /// 不经过签名阶段，没有草稿，走这里是预期的，不是 bug。
    static func advanceInstalled(
        of app: inout AppRecord,
        bundleIdentifier: String,
        expiryDate: Date
    ) {
        if app.pendingSignedSnapshot != nil {
            app.commitPendingSnapshot()
        } else {
            // 兜底：缓存重装不经过签名阶段（无草稿），以及老数据/异常路径，
            // 保留原有的回填逻辑，避免 UI 从「有到期日」退化成「无到期日」。
            if let binding = app.signingTargets.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                app.provisioningProfileUUID = binding.profileUUID
                app.provisioningProfileName = binding.profileName
                app.provisioningProfileCreationDate = binding.profileCreationDate
                app.provisioningProfileExpirationDate = binding.profileExpirationDate
            } else {
                app.provisioningProfileExpirationDate = expiryDate
            }
            app.expiryDate = expiryDate
        }
    }
}
