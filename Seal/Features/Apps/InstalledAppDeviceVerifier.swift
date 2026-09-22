import Foundation
@preconcurrency import Minimuxer

struct InstalledAppDeviceVerifier {
    static func isInstalled(bundleIdentifier: String) async throws -> Bool {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.isEmpty == false else {
            throw NSError(
                domain: "SealInstalledAppDeviceVerifier",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing bundle identifier"]
            )
        }

        // ⚠️ **必须有界**：`isAppInstalled` 是同步阻塞 FFI，在一条已死的 RSD 缓存会话上
        // **不报错、只阻塞到操作系统放弃**（与安装路径同一个失败模式）。
        // 只放到 `Task.detached` 是不够的 —— 那只是把它挪出主线程，**阻塞本身仍然无界**。
        // 超时按「不知道」处理（抛错），调用方本来就 fail closed（保守跳过，不删数据）。
        let outcome = await BlockingCall.bounded(seconds: BlockingCall.queryTimeoutSeconds) {
            // 查询前重置连接，避免使用已断开的 RSD 缓存连接导致误判
            Install.resetProvider()
            return try Minimuxer.isAppInstalled(bundleId: identifier)
        }
        guard let outcome else {
            throw NSError(
                domain: "SealInstalledAppDeviceVerifier",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Device probe timed out"]
            )
        }
        return try outcome.get()
    }
}
