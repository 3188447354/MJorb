import CryptoKit
import Foundation

struct BundleIDMapper: Sendable {
    let prefix: String

    init(prefix: String = "com.mjorb.seal.apps") {
        self.prefix = prefix
    }

    func mainBundleID(
        original: String,
        teamID: String,
        requested: String? = nil
    ) -> String {
        // 对齐 AltStore/SideStore 官方格式（原始+teamID），同时保留 Seal 标识：原始.seal.teamID。
        // 恒定不变：同一个应用 + 同一个 team 永远是同一个 Bundle ID，不随机。
        //
        // 关键：无论 requested 从哪来（UI 默认推荐值 / 旧的 preferredBundleIdentifier /
        // 用户手动输入），最终签名用的 Bundle ID 必须带「当前团队后缀」。
        // 若不强制附加，同一个 Bundle ID 会被不同 Apple ID（不同 team）的多个设备注册，
        // 一旦被某设备注册过，其他设备就无法再注册使用——这正是「bundle id 被占用后
        // 其他设备不能用」的根因。带 team 后缀后不同账号签名的是不同字符串，天然隔离。
        if let requested, requested.isEmpty == false {
            let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            // 已经是「当前 team 的后缀」则原样复用（续签复用已安装 / UI 默认推荐值）
            if trimmed.lowercased().hasSuffix(".seal.\(teamID.lowercased())") {
                return trimmed
            }
            // 否则统一换算成当前团队的推荐 ID（会自动剥离多余 .seal 中间缀）
            return BundleIDPolicy.recommendedBundleIdentifier(for: trimmed, teamID: teamID)
        }
        return BundleIDPolicy.recommendedBundleIdentifier(for: original, teamID: teamID)
    }

    func extensionBundleID(
        original: String,
        originalMainBundleID: String,
        mappedMainBundleID: String
    ) -> String {
        let originalLower = original.lowercased()
        let mainLower = originalMainBundleID.lowercased()
        if originalLower.hasPrefix(mainLower + ".") {
            let suffixIndex = original.index(
                original.startIndex,
                offsetBy: originalMainBundleID.count
            )
            let suffix = String(original[suffixIndex...])
            return mappedMainBundleID + suffix
        }
        return "\(mappedMainBundleID).e\(digest(original, length: 10))"
    }

    func extensionBundleID(
        original: String,
        mappedMainBundleID: String
    ) -> String {
        "\(mappedMainBundleID).e\(digest(original, length: 10))"
    }

    func appGroupID(original: String, teamID: String) -> String {
        // 和 Bundle ID 格式对齐：group.<去掉group.前缀的原始ID>.seal.<teamID>
        // 保留完整原始标识，多 group 自然唯一，teamID 保证全局唯一
        let base = original.hasPrefix("group.") ? String(original.dropFirst(6)) : original
        return "group.\(base).seal.\(teamID)"
    }

    private func digest(_ value: String, length: Int) -> String {
        let hash = SHA256.hash(data: Data(value.utf8))
        return hash.map { String(format: "%02x", $0) }
            .joined()
            .prefix(length)
            .description
    }
}
