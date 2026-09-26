import Foundation

/// 给**拿不到 SwiftUI environment** 的入口（App Intent / 后台回调）递同一份 `AppContainer`。
///
/// `SealApp.init()` 是**唯一**的构造点（`AppContainer.live()`）—— CoreData store、安装通道、
/// 签名协调器、维护作业都在那里装配好。而 App Intent 的 `perform()` 与
/// `UIApplicationDelegate` 的回调都拿不到它（它们不在 SwiftUI 的视图树里）⇒ 用一份
/// `@MainActor` 的进程内引用接出来。
///
/// 🔴 **只允许读，不允许在这里新建容器**：任何第二个 `AppContainer.live()` 都会造出第二份
/// CoreData store 与安装通道实例，从而绕过 `OperationCoordinator` 的单飞闸门 ——
/// 同一时刻两条 installd 命令正是本项目的历史事故（见守卫 R05 与
/// `SelfReplacementInstallGate`）。所以本文件里**没有**任何 `AppContainer.live()` 调用，
/// 守卫 R90 会断言这一点。
@MainActor
enum SealAppEnvironment {
    private static var installedContainer: AppContainer?

    /// 由 `SealApp.init()` 调用，只此一处。
    static func install(_ container: AppContainer) {
        installedContainer = container
    }

    /// 当前进程的容器；界面尚未装配完时为 `nil`（后台唤起极早期可能撞到）。
    static var container: AppContainer? { installedContainer }
}
