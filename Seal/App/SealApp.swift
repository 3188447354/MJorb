import SwiftUI

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
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(
                appsViewModel: container.appsViewModel,
                settingsViewModel: container.settingsViewModel,
                certificateExportHandler: container.certificateExportHandler
            )
        }
    }
}
