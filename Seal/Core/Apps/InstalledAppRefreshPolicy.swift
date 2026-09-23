import Foundation

/// 已安装页设备核验期间可能删除重复记录或已不在设备上的记录。
/// 自动核验必须在整轮结束后只重读一次，避免逐项删除触发的异步加载拿旧快照覆盖新列表。
enum InstalledAppRefreshPolicy {
    static func requiresReload(after mutations: [Bool]) -> Bool {
        mutations.contains(true)
    }
}
