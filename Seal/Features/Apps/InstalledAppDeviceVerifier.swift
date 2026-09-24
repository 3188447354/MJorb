import Foundation
@preconcurrency import Minimuxer

struct InstalledAppDeviceVerifier {
    private static let probeGate = InstalledAppRefreshProbeGate()

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
        switch await probeGate.begin() {
        case .ready:
            break
        case .inFlight:
            throw unavailableError(code: 3, description: "Device probe is already in progress")
        case .coolingDown:
            throw unavailableError(code: 4, description: "Device probe is cooling down after a timeout")
        }

        let outcome = await withTaskCancellationHandler {
            await BlockingCall.bounded(seconds: InstalledAppRefreshProbePolicy.timeoutSeconds) {
                // ⚠️ 这里**刻意不做**「重置 Install provider」这个动作（2026-09-25 删）。
                //
                // 它只清 Swift 侧的 provider 对象，**清不掉 Rust 的 RSD 会话缓存** ⇒
                // 对「死连接」这个场景**不是杠杆**。同一结论已在另两条路径落地：
                // `MinimuxerInstallChannel.verifyInstalled` 明确删掉了这个调用，
                // `DeviceProfileCleaner.probeInstalled` 也刻意不调（它的注释还点名
                // 「虽然 `InstalledAppDeviceVerifier` 会调」）。⇒ 保留它只会造成
                // 「死连接场景已经处理过」的**错觉**，把注意力从真正的补救
                //（`Minimuxer.reset()` 里的 `RustIdevice.invalidateConnection()`）上引开。
                //
                // 而且本函数会被 `reconcileInstalledAppsWithDevice` 的循环**逐条**调用，
                // 重置还可能拆掉正在服务安装的连接（R05：同一 Bundle ID 上不能有两个
                // 并发 installd 命令）。
                return try Minimuxer.isAppInstalled(bundleId: identifier)
            }
        } onCancel: {
            // 超时与取消都不会停止 FFI；在它自行返回前，不允许再叠加另一条设备查询。
            Task { await probeGate.finish(timedOut: true) }
        }
        if Task.isCancelled {
            await probeGate.finish(timedOut: true)
            throw CancellationError()
        }
        guard let outcome else {
            await probeGate.finish(timedOut: true)
            throw unavailableError(code: 2, description: "Device probe timed out")
        }
        await probeGate.finish(timedOut: false)
        return try outcome.get()
    }

    private static func unavailableError(code: Int, description: String) -> NSError {
        NSError(
            domain: "SealInstalledAppDeviceVerifier",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

actor InstalledAppRefreshProbeGate {
    enum Availability: Equatable {
        case ready
        case inFlight
        case coolingDown
    }

    private var isProbeInFlight = false
    private var cooldownUntil = Date.distantPast

    func begin() -> Availability {
        guard Date() >= cooldownUntil else { return .coolingDown }
        guard isProbeInFlight == false else { return .inFlight }
        isProbeInFlight = true
        return .ready
    }

    func finish(timedOut: Bool) {
        isProbeInFlight = false
        if timedOut {
            cooldownUntil = Date().addingTimeInterval(InstalledAppRefreshProbePolicy.timeoutCooldownSeconds)
        }
    }
}
