import Foundation

struct PreparedSigningWorkspace: Sendable {
    let rootURL: URL
    let payloadURL: URL
    let appURL: URL
    let mappedMainBundleID: String
    let bundleIDMappings: [String: String]

    /// `prepare` 里**解压**那一段的耗时（秒，2026-09-18）。
    ///
    /// 真机实测（构建 133）：抖音的 `prepare` 整体 **118 秒**，而它内部有**四次全树遍历**
    ///（解压 / 结构改写 / 瘦身 arm64e / 归一化）⇒ 不拆开就不知道 118 秒花在哪一段。
    /// 调用方拿**总耗时减掉它**就是「其余三段」的和 —— 两个数就足以定优化方向。
    ///
    /// ⚠️ **只用于日志归因，不参与任何判断**（不改变行为）。
    let unzipSeconds: Double

    var targetMainBundleIdentifier: String { mappedMainBundleID }
}

struct SignedBundleTarget: Sendable, Equatable {
    let bundleURL: URL
    let bundleIdentifier: String
    let isMainApplication: Bool
}
