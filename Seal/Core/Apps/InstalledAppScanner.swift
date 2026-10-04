import Foundation

/// 扫描设备上已安装的 App（私有 API）。
/// 用于重装 Seal 后找回之前签过的应用。
/// 注意：只能拿到基本信息（名称、版本、Bundle ID），拿不到图标和 IPA 文件。
final class InstalledAppScanner: Sendable {

    struct ScannedApp: Sendable {
        let bundleIdentifier: String
        let name: String
        let version: String
        let buildNumber: String
        let teamID: String?
    }

    /// 扫描所有已安装的应用，返回 Bundle ID -> ScannedApp
    /// 使用 LSApplicationWorkspace 私有 API，旁加载可用。
    func scanAll() async -> [ScannedApp] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let apps = Self.scanSync()
                continuation.resume(returning: apps)
            }
        }
    }

    private static func scanSync() -> [ScannedApp] {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return []
        }
        guard let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() else {
            return []
        }
        guard let appList = workspace.perform(NSSelectorFromString("allInstalledApplications"))?.takeUnretainedValue() as? [NSObject] else {
            return []
        }

        var result: [ScannedApp] = []
        for app in appList {
            guard let bundleID = app.value(forKey: "bundleIdentifier") as? String,
                  !bundleID.isEmpty else { continue }
            // 跳过系统应用和 Seal 自己（按需过滤）
            if bundleID.hasPrefix("com.apple.") { continue }

            let name = (app.value(forKey: "localizedName") as? String)
                ?? (app.value(forKey: "bundleIdentifier") as? String)
                ?? bundleID
            let version = (app.value(forKey: "bundleVersion") as? String) ?? ""
            let build = (app.value(forKey: "bundleShortVersionString") as? String) ?? ""
            // Team ID 需要从签名信息拿，这里先留空，调用方按需过滤
            result.append(ScannedApp(
                bundleIdentifier: bundleID,
                name: name,
                version: build.isEmpty ? version : build,
                buildNumber: version,
                teamID: nil
            ))
        }
        return result
    }
}
