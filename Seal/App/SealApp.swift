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
        // 后台保活改成按需启动：只在快捷指令触发续签时启动（SealRenewalIntent 里），
        // 续签完成后就停掉，不再常驻后台耗电。
        // 之前是 App 启动就常驻，导致即使用户不用也在后台跑，耗电快。
        // 钥匙串可访问性迁移：**必须同步、且必须在任何钥匙串读取之前**。
        // 锁屏下的后台续签要现读账号密钥与 anisette，条目若还是 `WhenUnlocked` 就会失败
        // （真机表现：日志只剩一句 `Seal.KeychainError 1`）。见 `SealKeychainAccessibility`。
        container.migrateKeychainAccessibilityIfNeeded()
        // 首次启动请求通知权限：快捷指令续签需要通过通知告知结果
        requestNotificationPermissionIfNeeded()
    }

    /// 首次启动时直接调系统原生权限框（只弹一次）。
    /// 测试环境下跳过：单元测试 host 启动时弹框会导致测试崩溃，
    /// UI 测试时弹框也会干扰用例（需 interruption handler 处理）。
    private nonisolated func requestNotificationPermissionIfNeeded() {
        #if DEBUG
        if NSClassFromString("XCTestCase") != nil { return }
        #endif
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
