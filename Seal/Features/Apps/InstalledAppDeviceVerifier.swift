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
                // 查询前重置连接，避免使用已断开的 RSD 缓存连接导致误判
                Install.resetProvider()
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
