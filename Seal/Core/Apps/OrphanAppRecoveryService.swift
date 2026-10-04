import Foundation

/// 重装后恢复：扫描设备上 Seal 之前签过的应用，创建"空壳"记录。
/// 空壳记录有名字、版本、Bundle ID（从已安装 App 读），但没有 IPA 文件和图标，
/// 需要用户重新导入 IPA 才能续签。
actor OrphanAppRecoveryService {
    private let scanner = InstalledAppScanner()
    private let appStore: any AppStore
    private let now: @Sendable () -> Date

    init(appStore: any AppStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.appStore = appStore
        self.now = now
    }

    /// 扫描并创建空壳记录。返回新创建的记录数。
    /// 只在应用列表为空时调用（重装后的首次恢复）。
    func recoverIfNeeded() async -> Int {
        // 如果已有记录，不重复扫
        guard let existing = try? await appStore.fetchAll(), existing.isEmpty else {
            return 0
        }
        let scanned = await scanner.scanAll()
        // 过滤 Seal 签过的：Bundle ID 包含 .seal.（Seal 的映射格式：原包名.seal.teamID）
        let sealApps = scanned.filter { $0.bundleIdentifier.contains(".seal.") }
        guard !sealApps.isEmpty else { return 0 }

        var created = 0
        for app in sealApps {
            // 从映射 ID 反推原始 Bundle ID（去掉 .seal.teamID 后缀）
            let originalID = Self.originalBundleID(from: app.bundleIdentifier)
            let record = AppRecord(
                originalBundleIdentifier: originalID,
                mappedBundleIdentifier: app.bundleIdentifier,
                name: app.name,
                version: app.version,
                buildNumber: app.buildNumber,
                size: 0,
                iconRelativePath: nil,
                state: .installed,
                ipaRelativePath: "",
                needsIPAImport: true,
                isSeal: false,
                importedAt: now()
            )
            try? await appStore.save(record)
            created += 1
        }
        return created
    }

    /// 从映射 ID 反推原始 ID：com.example.app.seal.TEAMID → com.example.app
    private static func originalBundleID(from mapped: String) -> String {
        // 找最后一个 .seal.，前面的是原始 ID
        if let range = mapped.range(of: ".seal.", options: .backwards) {
            return String(mapped[..<range.lowerBound])
        }
        return mapped
    }
}
