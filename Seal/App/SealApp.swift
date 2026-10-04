import SwiftUI
import UserNotifications

@main
@MainActor
struct SealApp: App {
    private let container: AppContainer
    private let notificationPresenter: SealNotificationPresenter

    init() {
        let notificationPresenter = SealNotificationPresenter()
        notificationPresenter.install()
        self.notificationPresenter = notificationPresenter
        let container = AppContainer.live()
        self.container = container
        // App Intent / 后台回调不在 SwiftUI 的视图树里、拿不到 environment
        // ⇒ 把这份容器接出去给它们用（只读，见 `SealAppEnvironment`）。
        SealAppEnvironment.install(container)
        // 后台保活：不打开 App 的续签里，快捷指令只负责「点火」，真正让它跑完的是这个
        // （静音音频无限循环 —— 否则后台窗口只有约 30 秒，大包续签必然半途而废）。
        // 幂等，重复调用无副作用。
        container.backgroundKeepAlive.start()
        // 后台定位保活：与静音音频形成双保险（音频被来电/闹钟/路由变更打断时，定位兜底）。
        container.locationKeepAlive.start()
        // 钥匙串可访问性迁移：**必须同步、且必须在任何钥匙串读取之前**。
        // 锁屏下的后台续签要现读账号密钥与 anisette，条目若还是 `WhenUnlocked` 就会失败
        // （真机表现：日志只剩一句 `Seal.KeychainError 1`）。见 `SealKeychainAccessibility`。
        container.migrateKeychainAccessibilityIfNeeded()
        // 首次启动请求通知权限：快捷指令续签需要通过通知告知结果
        requestNotificationPermissionIfNeeded()
    }

    /// 首次启动时直接调系统原生权限框（只弹一次）
    private nonisolated func requestNotificationPermissionIfNeeded() {
        let key = "SealNotificationPermissionRequested"
        guard UserDefaults.standard.bool(forKey: key) == false else { return }
        UserDefaults.standard.set(true, forKey: key)
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(
                appsViewModel: container.appsViewModel,
                settingsViewModel: container.settingsViewModel,
                certificateExportHandler: container.certificateExportHandler,
                migrateKeychainAccessibility: {
                    container.migrateKeychainAccessibilityIfNeeded()
                }
            )
        }
    }
}
