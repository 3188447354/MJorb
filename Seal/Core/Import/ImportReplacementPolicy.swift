import Foundation

/// 「导入新版 → 覆盖更新已安装应用」的判据。
///
/// 背景（2026-09-25 用户反馈）：`ImportWorkflow.commit` 原先**硬编码**
/// `let existing: AppRecord? = nil` —— 每次导入都新建一条待签名记录。于是导入一个
/// **已安装应用的新版本 IPA**（同 Bundle ID、同 Apple ID）时：
/// ① 记录落到「待签名」页，而不是「已安装」页 —— 用户看不到「更新」这个动作；
/// ② 新记录会从 `preferenceSource` 继承同一个**签名后**的 Bundle ID，签名时与那条已安装
///    记录争同一个身份，被 `SEAL-BUNDLE-004` 拦下（用户报「同 Bundle ID 冲突」）；
/// ③ 即便绕过，新记录不在已安装列表 ⇒ `forceResign` 为假 ⇒ 走不到续签那条免预检的路径。
///
/// 判据只认 `originalBundleIdentifier`（**导入包的原始身份**），**不认** mapped/preferred ——
/// 那两者是「签名后」的身份，拿它们匹配会把「同原始包、不同签名身份」的副本一并吞掉。
///
/// ⚠️ 只有**已安装**记录才构成覆盖更新候选。待签名记录不参与：仓库刻意支持
/// 「同一个 IPA 导入多个副本、用不同 Bundle ID 分别签名同时安装」，那条路径上的记录
/// 全都是待签名状态，绝不能被替换掉。
enum ImportReplacementPolicy {
    /// 覆盖更新的目标：与导入包同原始 Bundle ID 的一条**已安装**记录。
    /// 有多条时取最近安装/导入的那条（用户最新在用的那个）。
    static func installedReplacementCandidate(
        for parsed: ParsedIPA,
        in records: [AppRecord]
    ) -> AppRecord? {
        let target = normalizedBundleIdentifier(parsed.bundleIdentifier)
        guard target.isEmpty == false else { return nil }
        return records
            .filter { record in
                record.isSeal == false
                    && record.belongsInInstalledList
                    && normalizedBundleIdentifier(record.originalBundleIdentifier) == target
            }
            .max { lhs, rhs in
                installedTimestamp(lhs) < installedTimestamp(rhs)
            }
    }

    /// 同一判据的「按 id 复核」形态。用户在导入确认页停留期间记录可能被删除、或已不再是
    /// 已安装状态 ⇒ 提交前必须重新校验，复核不过就回落「新建」，绝不把别的记录覆盖掉。
    static func confirmedReplacement(
        appID: UUID,
        for parsed: ParsedIPA,
        in records: [AppRecord]
    ) -> AppRecord? {
        guard let candidate = installedReplacementCandidate(for: parsed, in: records),
              candidate.id == appID else { return nil }
        return candidate
    }

    /// Bundle ID 比较统一走这里：大小写与首尾空白都不敏感。
    /// 「导入包是不是 Seal 自己」那条兜底判据（`ImportWorkflow.existingSealRecord`）
    /// 也复用它 —— 两份 normalize 迟早漂移成「一处认、一处不认」。
    static func normalizedBundleIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func installedTimestamp(_ record: AppRecord) -> Date {
        record.lastInstalledAt ?? record.importedAt
    }
}
