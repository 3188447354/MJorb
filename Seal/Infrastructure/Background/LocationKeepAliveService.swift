import CoreLocation
import Foundation

/// 后台定位保活的授权处置（纯判据，可单测）。
///
/// `CLAuthorizationStatus` 是「系统怎么回答权限」，这里的判据把它折成
/// 「Seal 现在该做什么」。抽成纯函数的原因与 `BackgroundKeepAlivePolicy` 相同：
/// 判据落在 `CLLocationManager`（含系统交互的 framework 对象）里就测不到。
enum LocationKeepAliveAction: Equatable, Sendable {
    /// 权限尚未问过 —— 应当发起 `requestAlwaysAuthorization()`。
    case requestAuthorization
    /// 已授权（前台 / 始终均可）—— 应当真正启动后台定位。
    case start
    /// 被拒绝 / 受管控 —— 再怎么请求也不会授权，只能降级到仅音频保活。
    case unavailable
}

enum LocationKeepAlivePolicy {
    static func action(for status: CLAuthorizationStatus) -> LocationKeepAliveAction {
        switch status {
        case .notDetermined:
            return .requestAuthorization
        case .authorizedAlways, .authorizedWhenInUse:
            return .start
        case .denied, .restricted:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }
}

/// 后台保活的第二路：**后台定位**（`UIBackgroundModes: location`）。
///
/// ## 为什么要有第二路（2026-09-29）
/// `BackgroundKeepAliveService` 的静音音频是主保活，但它会被系统在多种场景停掉：
/// 来电、闹钟、拔耳机、连断蓝牙、媒体服务重置（那些场景各自有自愈，但**自愈之间有窗口**）。
/// 一旦音频停了而进程又恰好在后台，就再也没有任何东西给 Seal 续签任务续命 ——
/// 续签做到一半就被挂起，日志上却常常一行异常都没有。
///
/// 后台定位是 iOS 上仅次于 VoIP 的**持久**保活手段：只要定位在持续回调，进程就不会被挂起。
/// 上游 SideStore 自己就有备选的 `BackgroundLocationService`（`upstream-alignment.md` 已核对，
/// 它 `Info.plist` 也声明了 `location`），只是当年 Seal 按「跟」只做了 `audio`；
/// Locus / StikDebug 等依赖 LocalDevVPN 通道的同类 App 也都声明 `audio + location`。
/// 这里把它作为**第二路**补上，与音频形成双保险：哪一路先死、另一路兜住。
///
/// ⚠️ **这路不是「关机也不停」的银弹**：定位权限被拒时它静默不可用（只有音频一路），
/// 而 iOS 对「始终允许定位」的授予是用户可改的。它的价值是**多一层、且和音频的失效模式正交**。
@MainActor
final class LocationKeepAliveService: NSObject {
    private let logStore: SealLogStore?
    private let manager: CLLocationManager

    /// 是否**被请求过**（一旦置位不再复位；本类无 `stop()`，对齐 `BackgroundKeepAliveService`）。
    private(set) var isEnabled = false

    init(logStore: SealLogStore? = nil) {
        self.logStore = logStore
        self.manager = CLLocationManager()
        super.init()
        // 必须在 init 就挂上：授权结果、定位回调都依赖它。`CLLocationManager.delegate`
        // 是 weak，而这里被 `AppContainer` 持有一整个进程生命周期，不会提前释放。
        manager.delegate = self
    }

    /// 幂等启动。**失败不抛错**（保活失败不该让续签本身失败），但必须留痕。
    func start() {
        isEnabled = true
        manager.delegate = self
        apply(action: LocationKeepAlivePolicy.action(for: manager.authorizationStatus))
    }

    private func apply(afterAuthorizationChange status: CLAuthorizationStatus) {
        guard isEnabled else { return }
        apply(action: LocationKeepAlivePolicy.action(for: status))
    }

    private func apply(action: LocationKeepAliveAction) {
        switch action {
        case .requestAuthorization:
            // 结果走 `locationManagerDidChangeAuthorization` 回调，那里再决定是否真正启动。
            manager.requestAlwaysAuthorization()
        case .start:
            beginUpdating()
        case .unavailable:
            append(
                level: .warning,
                message: "后台定位保活无法启动：定位权限被拒绝，仅靠静音音频保活"
                    + "（锁屏续签在音频被中断时可能被系统挂起）",
                code: "SEAL-BACKGROUND-018"
            )
        }
    }

    private func beginUpdating() {
        // 只关心「进程不被挂起」，不关心坐标精度：中等精度 + 任何位移都回调，
        // 回调是保活的燃料，精度高只会多耗电。
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
        // 🔴 这两条是「后台定位保活」真正生效的关键（缺一不可，2026-09-29 对齐 Locus）：
        //   · `allowsBackgroundLocationUpdates = true` —— 缺了它，切后台定位立刻停；
        //   · `pausesLocationUpdatesAutomatically = false` —— **默认是 true**，系统在定位
        //     长时间不动时会自动暂停定位省电，保活会**静默失效**（正是「已启用却没用」的形态）。
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        // 隐藏状态栏蓝条：只在「始终允许」下生效（仅前台授权时系统强制显示，见 Apple 文档）。
        if #available(iOS 16.0, *) {
            manager.showsBackgroundLocationIndicator = false
        }
        manager.startUpdatingLocation()
        append(
            message: "后台保活已启动：后台定位持续更新，与静音音频形成双保险",
            code: "SEAL-BACKGROUND-017"
        )
    }

    private func append(
        level: SealLogEntry.Level = .info,
        message: String,
        code: String
    ) {
        guard let logStore else { return }
        Task {
            try? await logStore.append(
                category: .system,
                level: level,
                message: message,
                code: code
            )
        }
    }
}

extension LocationKeepAliveService: CLLocationManagerDelegate {
    /// 收到定位回调 = 进程仍在被系统调度，保活生效。坐标本身用不到。
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {}

    /// 授权变化不发生在 MainActor 隔离域，这里只读参数、再转发回 MainActor。
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.apply(afterAuthorizationChange: status)
        }
    }
}