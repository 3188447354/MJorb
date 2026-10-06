import Foundation

/// 两阶段提交的草稿：签名/续签阶段先写这里，确认成功后整体转正到 AppRecord 顶层。
/// nil = 无进行中的签名/续签。UI 只读顶层 committed 值，不读这里。
struct PendingSignedSnapshot: Codable, Equatable, Sendable {
    var expiryDate: Date?
    var provisioningProfileUUID: String?
    var provisioningProfileName: String?
    var provisioningProfileCreationDate: Date?
    var provisioningProfileExpirationDate: Date?
    var certificateSerialNumber: String?
    var signingTargets: [SigningTargetRecord]
    var extensionSnapshots: [PendingExtensionSnapshot]

    struct PendingExtensionSnapshot: Codable, Equatable, Sendable {
        var bundleIdentifier: String
        var provisioningProfileUUID: String?
        var provisioningProfileName: String?
        var provisioningProfileExpirationDate: Date?
        var certificateSerialNumber: String?
    }
}

extension AppRecord {
    /// pending → committed 转正：安装/注入确认后，把草稿整体写到顶层并清空。
    /// 无 pending 时直接返回。UI 只读顶层。
    mutating func commitPendingSnapshot() {
        guard let pending = pendingSignedSnapshot else { return }
        provisioningProfileUUID = pending.provisioningProfileUUID
        provisioningProfileName = pending.provisioningProfileName
        provisioningProfileCreationDate = pending.provisioningProfileCreationDate
        provisioningProfileExpirationDate = pending.provisioningProfileExpirationDate
        expiryDate = pending.expiryDate
        certificateSerialNumber = pending.certificateSerialNumber
        signingTargets = pending.signingTargets
        for snapshot in pending.extensionSnapshots {
            if let index = extensions.firstIndex(where: { $0.mappedBundleIdentifier == snapshot.bundleIdentifier }) {
                extensions[index].provisioningProfileUUID = snapshot.provisioningProfileUUID
                extensions[index].provisioningProfileName = snapshot.provisioningProfileName
                extensions[index].provisioningProfileExpirationDate = snapshot.provisioningProfileExpirationDate
                extensions[index].certificateSerialNumber = snapshot.certificateSerialNumber
            }
        }
        pendingSignedSnapshot = nil
    }

    /// 丢弃 pending（失败/回滚时），顶层保持旧的已确认值。
    mutating func discardPendingSnapshot() {
        pendingSignedSnapshot = nil
    }
}
