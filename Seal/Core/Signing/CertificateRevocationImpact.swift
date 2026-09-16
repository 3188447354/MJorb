import Foundation

/// 撤销某个证书前，先算清楚「会影响谁」。
///
/// 序列号一律经 `SigningCertificateSelectionPolicy.normalizedSerialNumber(_:)` 归一化后比较：
/// AltSign 会剥掉最高半字节的前导 `0`，而 DER 来源（证书列表 / 描述文件）会保留，
/// 直接 `caseInsensitiveCompare` 会把同一证书误判成两个（见 DEBUG_LOG 坑位 1）。
enum CertificateRevocationImpact {
    /// 所有能从本地记录确认使用该证书的 App（保持传入顺序）。
    ///
    /// 既检查旧记录里的顶层序列号，也检查每个签名 target 的序列号：
    /// 扩展 target 可能已经记录了证书，但旧数据的顶层字段为空或已被轮换。
    /// 这份完整列表用于证书页展示「到底关联了哪些 App」。
    static func associatedApps(serialNumber: String, apps: [AppRecord]) -> [AppRecord] {
        let target = SigningCertificateSelectionPolicy.normalizedSerialNumber(serialNumber)
        return apps.filter { app in
            if let serial = app.certificateSerialNumber,
               SigningCertificateSelectionPolicy.normalizedSerialNumber(serial) == target {
                return true
            }
            return app.signingTargets.contains { signingTarget in
                signingTarget.certificateSerialNumbers.contains {
                    SigningCertificateSelectionPolicy.normalizedSerialNumber($0) == target
                }
            }
        }
    }

    /// 本机**已安装**、且用该证书签名的应用（保持传入顺序）。
    ///
    /// 只统计已安装的：未安装的包重新签一次即可，撤销证书不会造成实际损失；
    /// 而已安装的应用会因为证书被撤销而无法启动。
    static func affectedApps(serialNumber: String, apps: [AppRecord]) -> [AppRecord] {
        let target = SigningCertificateSelectionPolicy.normalizedSerialNumber(serialNumber)
        return apps.filter { app in
            guard app.state == .installed else { return false }
            guard let serial = app.certificateSerialNumber,
                  serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return false
            }
            return SigningCertificateSelectionPolicy.normalizedSerialNumber(serial) == target
        }
    }

    /// 证书卡片「本机已安装 App」清单展示用：与行标签（`associatedApps`）**同一套关联判定**
    /// ——顶层序列号或任一签名 target 的序列号命中即算关联——再只保留本机视为已安装的记录。
    ///
    /// 为什么不能直接用 `affectedApps`：那个判定只看顶层 `certificateSerialNumber` 且要求
    /// `state == .installed`，与行标签用的 `associatedApps` 不同源，于是同一张证书会出现
    /// 「标签说本机已安装 App 在用、下面的清单却说暂无」的自相矛盾；Seal 自身
    /// （`belongsInInstalledList` 恒为真）尤其容易被漏掉。
    /// 撤销影响评估仍走 `affectedApps`（口径更严，只算真正会失效的已装应用），两者不要合并。
    static func installedAppsAssociated(serialNumber: String, apps: [AppRecord]) -> [AppRecord] {
        associatedApps(serialNumber: serialNumber, apps: apps)
            .filter(\.belongsInInstalledList)
    }

    /// 该证书是否就是当前运行 Seal 的真实 CMS 签名者。
    /// 真实签名者被撤，Seal 立即「不再可用」；任何撤销入口都必须先挡住它。
    /// 返回 false 只表示「无法证明是 A」，绝不表示「可以放心撤」——签名者未知时
    /// 调用方必须整体停止撤销。
    static func isActualSealSigner(serialNumber: String, actualSealSignerSerialNumber: String?) -> Bool {
        guard let signer = actualSealSignerSerialNumber,
              signer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        return SigningCertificateSelectionPolicy.normalizedSerialNumber(serialNumber)
            == SigningCertificateSelectionPolicy.normalizedSerialNumber(signer)
    }

    /// 该证书是否就是本机当前用于签名的那一张。
    /// 撤销它会同时清掉本机 P12 与账号上的序列号记录。
    static func isLocalCertificate(serialNumber: String, account: AppleAccountRecord) -> Bool {
        guard let local = account.certificateSerialNumber,
              local.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        return SigningCertificateSelectionPolicy.normalizedSerialNumber(local)
            == SigningCertificateSelectionPolicy.normalizedSerialNumber(serialNumber)
    }

    /// 二次确认用的影响说明。只陈述事实，不替用户做决定。
    static func warningMessage(
        serialNumber: String,
        apps: [AppRecord],
        isLocalCertificate: Bool
    ) -> String {
        var lines: [String] = []

        let affected = affectedApps(serialNumber: serialNumber, apps: apps)
        if affected.isEmpty {
            lines.append("本机没有已安装的应用在用这个证书。")
        } else {
            let names = affected.prefix(3).map(\.name).joined(separator: "、")
            let tail = affected.count > 3 ? " 等 \(affected.count) 个应用" : ""
            lines.append("撤销后，用这个证书签名的已安装应用会失效：\(names)\(tail)。需要重新签名安装才能恢复。")
        }

        if isLocalCertificate {
            lines.append("这是本机当前使用的证书，撤销后会同时清除本机证书；下次签名时会自动重新创建。")
        }

        lines.append("证书一旦撤销无法恢复。")
        return lines.joined(separator: "\n")
    }
}
