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

    /// 结构改写（BundleID / URL scheme / UTI / 显示名 / 图标 / 删 Watch·AppClip /
    /// 清 SC_Info 引用 / 清注入残留 / 删空目录）的耗时（秒）。
    let rewriteSeconds: Double

    /// 瘦身（剥离 arm64e 架构）的耗时（秒）。
    let stripSeconds: Double

    /// 归一化（根目录 framework/dylib → `Frameworks/` + 改写 `@executable_path`）
    /// **+ 扩展 BundleID 改写 + 删旧签名**的耗时（秒）。
    let normalizeSeconds: Double

    var targetMainBundleIdentifier: String { mappedMainBundleID }
}

struct SignedBundleTarget: Sendable, Equatable {
    let bundleURL: URL
    let bundleIdentifier: String
    let isMainApplication: Bool
}
