import AppIntents
import Foundation

/// `RefreshAllAppsIntent.perform()` 的两种结果。
///
/// **刻意不用 `Bool`** ——「没启动」只有一种表现（返回 `false`），但有两种完全不同的原因，
/// 下一步动作也不同：容器还没装配好是**等一等再试**，而本地存储初始化失败是
/// **先打开一次 Seal 把数据修好**。折成 `Bool` 就只能给一句没有指向的提示。
enum SealRenewalIntentOutcome: Sendable {
    /// 已经点火，续签在后台跑。
    case started
    /// 界面尚未装配完（后台唤起的极早期），或本地存储初始化失败。
    case notReady
}

/// 「续签全部应用」——**不打开 App** 的那条入口。
///
/// 🔴 它只负责**点火**：iOS 给后台任务的时间窗只有约 30 秒，而大包续签（抖音 658 MB）
/// 要几分钟到十几分钟。真正让续签跑完的是 `BackgroundKeepAliveService`
/// （静音音频无限循环，由 `SealApp.init()` 与 `AppsViewModel` 的续签入口启动）。
///
/// ⚠️ **不自己拼一套续签流程**：直接调 `AppsViewModel.refreshAllFromBackgroundTrigger()` ——
/// 它复用「Seal 最后」排序、队列持久化、中断恢复与单飞闸门（`batchRefreshTask` /
/// `signingTask` / `OperationCoordinator`）。另起一套会绕过这些，造出第二次 installd
/// 命令（历史事故，见守卫 R05）。
struct RefreshAllAppsIntent: AppIntent {
    /// ⚠️ 用 `let` 而不是 `var`：`static var` 是**非隔离的全局可变状态**，
    /// 在 `SWIFT_STRICT_CONCURRENCY = complete` + Swift 6 下会报
    /// 「static property 'title' is not concurrency-safe …」；`AppIntent` 的这条要求
    /// 是 `{ get }`，`let` 同样满足（本机无 Swift 工具链 ⇒ 这类错只能靠云构建暴露，
    /// 所以写的时候就要避开）。
    static let title: LocalizedStringResource = "续签全部应用"

    /// 后台执行，**不把 Seal 拉到前台** —— 这正是「不打开 App」这条需求本身。
    /// ⚠️ 改成 `true` 会让快捷指令自动化每次弹出 Seal 界面，等于这条链路白做。
    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await MainActor.run { () -> SealRenewalIntentOutcome in
            guard let container = SealAppEnvironment.container else { return .notReady }
            // 先起保活、再点火：反过来的话，点火之后进程可能立刻被系统挂起，
            // 续签任务还没跑到第一次网络往返就停了（后台没有界面，用户看不到）。
            container.backgroundKeepAlive.start()
            container.appsViewModel.refreshAllFromBackgroundTrigger()
            return .started
        }
        switch outcome {
        case .started:
            return .result(dialog: "已在后台开始续签全部应用。")
        case .notReady:
            return .result(dialog: "Seal 还没准备好，请先打开一次 Seal 再试。")
        }
    }
}

/// 让「续签全部应用」在快捷指令里**开箱可见** —— 用户不用自己拼动作。
///
/// ⚠️ Apple 的硬要求：**每一条** phrase 都必须带 `\(.applicationName)`，
/// 否则这条 App Shortcut **不会注册** —— 编译不报错、运行不报错，只是界面上永远不出现，
/// 排查起来极贵。守卫 R90 按「每条 phrase 都含 `.applicationName`」钉住。
struct SealAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshAllAppsIntent(),
            phrases: [
                "用 \(.applicationName) 续签全部应用",
                "\(.applicationName) 续签全部应用"
            ],
            shortTitle: "续签全部应用",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
